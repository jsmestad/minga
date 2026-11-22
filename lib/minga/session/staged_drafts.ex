defmodule Minga.Session.StagedDrafts do
  @moduledoc """
  On-disk store for staged agent edits, so they survive a full Minga restart.

  Approved agent edits wait in memory until the user publishes or discards them. This module keeps a durable copy next to the other session files, keyed by project and by staging view:

      $XDG_DATA_HOME/minga/staged_drafts/<project key>/<view key>/<path key>.json

  The keys are SHA-256 hashes, so file names never reveal project paths. Files are grouped by the identity of the staging view (`MingaAgent.ProjectView` id), not by workspace: two views that claim the same workspace never overwrite or delete each other's drafts. The workspace id is an attribute stored in each draft.

  Each draft is one JSON file, written atomically (temporary file, then rename), so a crash leaves either the previous complete draft or the new one. The file carries a `version` field. The project root, view id, and path are Base64-encoded, because names can be arbitrary bytes that JSON cannot hold, and so are the base and staged bytes. A `base_sha256` fingerprint guards the base against corruption.

  The drafts are user file content. Every store directory must be a real directory (not a symlink) owned by the current user and not writable by group or others; it is created with mode `0700`, and a directory that fails the check is refused for both writing and loading. Draft files get mode `0600` before they become visible under their final name. Reads accept regular files only and are bounded by `max_draft_bytes/1`. A draft above `max_file_bytes/1` is never saved; `write_lost/6` replaces its stored copy with a content-free marker, so the next start reports it as lost instead of restoring an older version.

  This module only reads and writes files. `MingaAgent.StagedDraftKeeper` decides when to write and delete them.
  """

  import Bitwise, only: [band: 2]

  alias Minga.SecureFile
  alias Minga.Session.StagedDraft

  @format "minga-staged-draft"
  @current_version 1
  @extension ".json"

  # The editor refuses to open files above 10 MiB by default; agent changesets
  # stage files without that limit. 64 MiB of base plus 64 MiB of content is
  # well above any source file an agent edits, and keeps a corrupt or hostile
  # draft from exhausting the keeper.
  @max_file_bytes 64 * 1024 * 1024

  @typedoc "Why one stored draft is gone for good. Its file is deleted."
  @type lost_reason ::
          :invalid_format
          | :base_fingerprint_mismatch
          | :project_mismatch
          | :invalid_path
          | :too_large
          | :not_a_regular_file
          | {:unsupported_version, term()}

  @typedoc "Why one stored draft cannot be read now. Its file is kept for a later start."
  @type retained_reason :: {:read_failed, term()}

  @typedoc "One loaded draft file."
  @type entry ::
          {:ok, String.t(), StagedDraft.t()}
          | {:lost, String.t(), String.t(), lost_reason()}
          | {:retained, String.t(), String.t(), retained_reason()}

  @typedoc "The stored drafts of one staging view."
  @type stored_view :: %{
          dir: String.t(),
          view_id: String.t(),
          workspace_id: non_neg_integer() | nil,
          entries: [entry()]
        }

  @doc "Largest base or staged content, in bytes, that is persisted (`opts[:max_file_bytes]`, default 64 MiB)."
  @spec max_file_bytes(keyword()) :: pos_integer()
  def max_file_bytes(opts \\ []), do: Keyword.get(opts, :max_file_bytes, @max_file_bytes)

  @doc "Largest draft file, in bytes, that is read back: Base64 of a maximal base and content, plus room for the envelope."
  @spec max_draft_bytes(keyword()) :: pos_integer()
  def max_draft_bytes(opts \\ []), do: 2 * div(max_file_bytes(opts) * 4, 3) + 64 * 1024

  @doc "Returns the root directory of the staged draft store."
  @spec dir(keyword()) :: String.t()
  def dir(opts \\ []) do
    Keyword.get_lazy(opts, :staged_drafts_dir, fn ->
      Path.join(
        System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
        "minga/staged_drafts"
      )
    end)
  end

  @doc "Returns the directory holding one view's drafts."
  @spec view_dir(String.t(), String.t(), keyword()) :: String.t()
  def view_dir(project_root, view_id, opts \\ [])
      when is_binary(project_root) and is_binary(view_id) do
    Path.join(project_dir(project_root, opts), hash(view_id))
  end

  @doc "Returns the file that stores the draft for `path`."
  @spec draft_file(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def draft_file(project_root, view_id, path, opts \\ []) when is_binary(path) do
    Path.join(view_dir(project_root, view_id, opts), hash(path) <> @extension)
  end

  @doc """
  Returns the uid that must own the store directories.

  `opts[:owner_uid]` wins; otherwise the uid is read from a file this process creates, which avoids spawning an OS process.
  """
  @spec owner_uid(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def owner_uid(opts \\ []) do
    case Keyword.fetch(opts, :owner_uid) do
      {:ok, uid} when is_integer(uid) -> {:ok, uid}
      :error -> probe_uid()
    end
  end

  @doc "Atomically writes one draft of `view_id`, staged for `workspace_id`."
  @spec write(String.t(), String.t(), non_neg_integer(), StagedDraft.t(), keyword()) ::
          :ok | {:error, term()}
  def write(project_root, view_id, workspace_id, %StagedDraft{} = draft, opts \\ [])
      when is_integer(workspace_id) and workspace_id >= 0 do
    target = draft_file(project_root, view_id, draft.path, opts)

    with :ok <- within_size_limit(draft, opts),
         {:ok, json} <- encode_json(encode(project_root, view_id, workspace_id, draft)) do
      publish(project_root, view_id, opts, target, json)
    end
  end

  @doc """
  Replaces the stored draft for `path` with a marker that it is lost, for a draft that cannot be saved (`:too_large`).

  The marker names the path and the reason and holds no content, so the next start reports the draft as lost instead of restoring an older saved version.
  """
  @spec write_lost(String.t(), String.t(), non_neg_integer(), String.t(), :too_large, keyword()) ::
          :ok | {:error, term()}
  def write_lost(project_root, view_id, workspace_id, path, :too_large, opts \\ [])
      when is_binary(path) and is_integer(workspace_id) and workspace_id >= 0 do
    marker = %{
      "format" => @format,
      "version" => @current_version,
      "project_root" => Base.encode64(project_root),
      "view_id" => Base.encode64(view_id),
      "workspace_id" => workspace_id,
      "path" => Base.encode64(path),
      "lost" => "too_large"
    }

    with {:ok, json} <- encode_json(marker) do
      publish(project_root, view_id, opts, draft_file(project_root, view_id, path, opts), json)
    end
  end

  @spec publish(String.t(), String.t(), keyword(), String.t(), String.t()) ::
          :ok | {:error, term()}
  defp publish(project_root, view_id, opts, target, json) do
    tmp = "#{target}.#{System.unique_integer([:positive, :monotonic])}.tmp"

    with :ok <- ensure_private_dirs(project_root, view_id, opts),
         :ok <- write_private(tmp, json),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  @doc """
  Deletes every stored draft of one view except the drafts for `keep_paths`, plus leftover temporary files.

  Only the owner of the view (the process that writes its drafts) may call this, and never while one of its own writes is in progress: temporary files are removed here, not when loading, because a temporary file can belong to a write that is still running.
  """
  @spec prune(String.t(), String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def prune(project_root, view_id, keep_paths, opts \\ []) when is_list(keep_paths) do
    dir = view_dir(project_root, view_id, opts)
    keep = MapSet.new(keep_paths, &(hash(&1) <> @extension))

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&stale_name?(&1, keep))
        |> Enum.reduce(:ok, fn name, result ->
          first_error(result, remove_file(Path.join(dir, name)))
        end)

      {:error, :enoent} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @spec stale_name?(String.t(), MapSet.t(String.t())) :: boolean()
  defp stale_name?(name, keep) do
    String.ends_with?(name, ".tmp") or
      (String.ends_with?(name, @extension) and not MapSet.member?(keep, name))
  end

  @doc "Deletes the stored draft of one view for `path`. A missing file is not an error."
  @spec delete(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(project_root, view_id, path, opts \\ []) do
    project_root |> draft_file(view_id, path, opts) |> remove_file()
  end

  @doc "Deletes a loaded view's directory, for a view none of whose drafts can be restored."
  @spec remove_view_dir(stored_view()) :: :ok | {:error, term()}
  def remove_view_dir(%{dir: dir}) do
    case File.rm_rf(dir) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  @doc """
  Deletes every stored draft of one view.

  The project directory is left in place, even when empty: removing it could race with another writer (another view, or another Minga instance) that has just checked it and is about to create its own view directory inside it.
  """
  @spec delete_view(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete_view(project_root, view_id, opts \\ []) do
    case File.rm_rf(view_dir(project_root, view_id, opts)) do
      {:ok, _removed} ->
        :ok

      {:error, reason, _path} ->
        {:error, reason}
    end
  end

  @doc "Removes one stored draft file, for example a draft reported as lost."
  @spec remove_file(String.t()) :: :ok | {:error, term()}
  def remove_file(file) when is_binary(file) do
    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Loads every stored draft of a project, grouped by staging view.

  A draft that can never be restored is returned as `{:lost, file, name, reason}`; one that cannot be read now is `{:retained, file, name, reason}`. `name` is the draft's path when the file still names it. Temporary files are skipped and left alone: one may belong to a write that is still in progress (`prune/4` removes leftovers for the view's owner). Returns `{:error, reason}` without reading anything when a store directory fails the privacy check.
  """
  @spec load(String.t(), keyword()) :: {:ok, [stored_view()]} | {:error, term()}
  def load(project_root, opts \\ []) when is_binary(project_root) do
    project = project_dir(project_root, opts)

    with {:ok, uid} <- owner_uid(opts),
         :ok <- verify_existing_private(dir(opts), uid),
         :ok <- verify_existing_private(project, uid),
         {:ok, names} <- list_dir(project) do
      dirs = names |> Enum.sort() |> Enum.map(&Path.join(project, &1))

      with :ok <- all_ok(dirs, &verify_private(&1, uid)) do
        {:ok, Enum.flat_map(dirs, &List.wrap(load_view(&1, project_root, opts)))}
      end
    else
      :absent -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec project_dir(String.t(), keyword()) :: String.t()
  defp project_dir(project_root, opts), do: Path.join(dir(opts), hash(project_root))

  @spec list_dir(String.t()) :: {:ok, [String.t()]} | :absent | {:error, term()}
  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, reason}
    end
  end

  # Applies `check` in order and stops at the first error.
  @spec all_ok([String.t()], (String.t() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  defp all_ok(items, check) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case check.(item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec load_view(String.t(), String.t(), keyword()) :: stored_view() | nil
  defp load_view(dir, project_root, opts) do
    entries =
      case File.ls(dir) do
        {:ok, names} ->
          names
          |> Enum.sort()
          |> Enum.flat_map(&load_entry(Path.join(dir, &1), project_root, opts))

        {:error, _reason} ->
          []
      end

    case entries do
      [] -> nil
      entries -> Map.put(stored_view(entries), :dir, dir)
    end
  end

  # The view id and workspace id come from the decoded drafts; a view whose
  # drafts are all unreadable is still reported so its losses are named.
  @spec stored_view([{entry(), String.t() | nil, non_neg_integer() | nil}, ...]) :: stored_view()
  defp stored_view(decoded) do
    owner = Enum.find_value(decoded, fn {_entry, view_id, ws} -> view_id && {view_id, ws} end)
    {view_id, workspace_id} = owner || {"", nil}

    %{
      view_id: view_id,
      workspace_id: workspace_id,
      entries: Enum.map(decoded, &elem(&1, 0))
    }
  end

  @spec load_entry(String.t(), String.t(), keyword()) :: [
          {entry(), String.t() | nil, non_neg_integer() | nil}
        ]
  defp load_entry(file, project_root, opts) do
    # A temporary file may belong to a write that is still in progress, in
    # this process or another; loading never touches it.
    if String.ends_with?(file, @extension),
      do: [read_entry(file, project_root, opts)],
      else: []
  end

  @spec read_entry(String.t(), String.t(), keyword()) ::
          {entry(), String.t() | nil, non_neg_integer() | nil}
  defp read_entry(file, project_root, opts) do
    case SecureFile.read(file, max_draft_bytes(opts)) do
      {:ok, data} ->
        decode_file(file, data, project_root)

      {:error, {:file_too_large, _path, _size, _max}} ->
        {{:lost, file, Path.basename(file), :too_large}, nil, nil}

      {:error, {:non_regular_file, _path, _type}} ->
        {{:lost, file, Path.basename(file), :not_a_regular_file}, nil, nil}

      {:error, {:file_read_failed, _path, reason}} ->
        {{:retained, file, Path.basename(file), {:read_failed, reason}}, nil, nil}

      {:error, _changed_during_read} ->
        {{:retained, file, Path.basename(file), {:read_failed, :changed_during_read}}, nil, nil}
    end
  end

  @spec decode_file(String.t(), binary(), String.t()) ::
          {entry(), String.t() | nil, non_neg_integer() | nil}
  defp decode_file(file, data, project_root) do
    case JSON.decode(data) do
      {:ok, %{} = map} -> decode(file, map, project_root)
      _invalid -> {{:lost, file, Path.basename(file), :invalid_format}, nil, nil}
    end
  end

  @spec encode(String.t(), String.t(), non_neg_integer(), StagedDraft.t()) :: map()
  defp encode(project_root, view_id, workspace_id, %StagedDraft{} = draft) do
    %{
      "format" => @format,
      "version" => @current_version,
      "project_root" => Base.encode64(project_root),
      "view_id" => Base.encode64(view_id),
      "workspace_id" => workspace_id,
      "path" => Base.encode64(draft.path),
      "base_sha256" => StagedDraft.base_fingerprint(draft),
      "base" => encode_bytes(draft.base),
      "deleted" => draft.content == :deleted,
      "content" => encode_content(draft.content)
    }
  end

  @spec encode_json(map()) :: {:ok, String.t()} | {:error, :invalid_format}
  defp encode_json(map) do
    {:ok, JSON.encode!(map)}
  rescue
    _error -> {:error, :invalid_format}
  end

  @spec encode_bytes(binary() | nil) :: String.t() | nil
  defp encode_bytes(nil), do: nil
  defp encode_bytes(bytes), do: Base.encode64(bytes)

  @spec encode_content(StagedDraft.content()) :: String.t() | nil
  defp encode_content(:deleted), do: nil
  defp encode_content(bytes), do: Base.encode64(bytes)

  @spec within_size_limit(StagedDraft.t(), keyword()) :: :ok | {:error, :draft_too_large}
  defp within_size_limit(%StagedDraft{base: base, content: content}, opts) do
    max = max_file_bytes(opts)

    if byte_size_or_zero(base) <= max and byte_size_or_zero(content) <= max,
      do: :ok,
      else: {:error, :draft_too_large}
  end

  @spec byte_size_or_zero(binary() | atom() | nil) :: non_neg_integer()
  defp byte_size_or_zero(bytes) when is_binary(bytes), do: byte_size(bytes)
  defp byte_size_or_zero(_none), do: 0

  @spec decode(String.t(), map(), String.t()) ::
          {entry(), String.t() | nil, non_neg_integer() | nil}
  defp decode(file, %{"format" => @format, "version" => @current_version} = map, root) do
    name = lost_name(map, file)

    with {:ok, path} <- decode_path(Map.get(map, "path")),
         {:ok, view_id, workspace_id} <- decode_owner(map, root),
         :ok <- not_lost(map),
         {:ok, base} <- decode_optional_bytes(Map.get(map, "base")),
         :ok <- verify_base(base, Map.get(map, "base_sha256")),
         {:ok, content} <- decode_content(map) do
      {{:ok, file, StagedDraft.new(path, base, content)}, view_id, workspace_id}
    else
      {:error, reason} -> {{:lost, file, name, reason}, nil, nil}
    end
  end

  defp decode(file, %{"format" => @format, "version" => version} = map, _root)
       when version != @current_version,
       do: {{:lost, file, lost_name(map, file), {:unsupported_version, version}}, nil, nil}

  defp decode(file, map, _root),
    do: {{:lost, file, lost_name(map, file), :invalid_format}, nil, nil}

  @spec not_lost(map()) :: :ok | {:error, :too_large}
  defp not_lost(%{"lost" => "too_large"}), do: {:error, :too_large}
  defp not_lost(_map), do: :ok

  @spec lost_name(map(), String.t()) :: String.t()
  defp lost_name(map, file) do
    with encoded when is_binary(encoded) <- Map.get(map, "path"),
         {:ok, path} when path != "" <- Base.decode64(encoded) do
      path
    else
      _unnamed -> Path.basename(file)
    end
  end

  @spec decode_path(term()) :: {:ok, String.t()} | {:error, :invalid_path}
  defp decode_path(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, path} when path != "" -> relative_path(path)
      _invalid -> {:error, :invalid_path}
    end
  end

  defp decode_path(_encoded), do: {:error, :invalid_path}

  @spec relative_path(String.t()) :: {:ok, String.t()} | {:error, :invalid_path}
  defp relative_path(path) do
    if Path.type(path) == :relative and ".." not in Path.split(path),
      do: {:ok, path},
      else: {:error, :invalid_path}
  end

  @spec decode_owner(map(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, :project_mismatch}
  defp decode_owner(%{"project_root" => root64, "view_id" => view64, "workspace_id" => ws}, root)
       when is_binary(root64) and is_binary(view64) and is_integer(ws) and ws >= 0 do
    with {:ok, ^root} <- Base.decode64(root64),
         {:ok, view_id} when view_id != "" <- Base.decode64(view64) do
      {:ok, view_id, ws}
    else
      _mismatch -> {:error, :project_mismatch}
    end
  end

  defp decode_owner(_map, _root), do: {:error, :project_mismatch}

  @spec decode_optional_bytes(term()) :: {:ok, binary() | nil} | {:error, :invalid_format}
  defp decode_optional_bytes(nil), do: {:ok, nil}

  defp decode_optional_bytes(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_format}
    end
  end

  defp decode_optional_bytes(_encoded), do: {:error, :invalid_format}

  @spec verify_base(binary() | nil, term()) :: :ok | {:error, :base_fingerprint_mismatch}
  defp verify_base(nil, nil), do: :ok

  defp verify_base(base, fingerprint) when is_binary(base) and is_binary(fingerprint) do
    if StagedDraft.fingerprint(base) == fingerprint,
      do: :ok,
      else: {:error, :base_fingerprint_mismatch}
  end

  defp verify_base(_base, _fingerprint), do: {:error, :base_fingerprint_mismatch}

  @spec decode_content(map()) :: {:ok, StagedDraft.content()} | {:error, :invalid_format}
  defp decode_content(%{"deleted" => true}), do: {:ok, :deleted}

  defp decode_content(%{"deleted" => false, "content" => encoded}) when is_binary(encoded),
    do: decode_optional_bytes(encoded)

  defp decode_content(_map), do: {:error, :invalid_format}

  # ── Private directories ─────────────────────────────────────────────────

  @spec ensure_private_dirs(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defp ensure_private_dirs(project_root, view_id, opts) do
    root = dir(opts)

    with {:ok, uid} <- owner_uid(opts),
         :ok <- File.mkdir_p(Path.dirname(root)) do
      all_ok(
        [root, project_dir(project_root, opts), view_dir(project_root, view_id, opts)],
        &create_private(&1, uid)
      )
    end
  end

  @spec create_private(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp create_private(dir, uid) do
    case File.mkdir(dir) do
      result when result in [:ok, {:error, :eexist}] -> verify_private(dir, uid)
      {:error, _reason} = error -> error
    end
  end

  @spec verify_existing_private(String.t(), non_neg_integer()) ::
          :ok | :absent | {:error, term()}
  defp verify_existing_private(dir, uid) do
    case File.lstat(dir) do
      {:error, :enoent} -> :absent
      _exists -> verify_private(dir, uid)
    end
  end

  # A store directory must be a real directory owned by this user. It is made
  # 0700, and refused if it stays writable by group or others.
  @spec verify_private(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp verify_private(dir, uid) do
    with {:ok, %File.Stat{type: :directory, uid: ^uid}} <- File.lstat(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} <- File.lstat(dir),
         0 <- band(mode, 0o022) do
      :ok
    else
      {:ok, %File.Stat{type: :directory}} -> {:error, {:insecure_directory, dir, :owner}}
      {:ok, %File.Stat{type: type}} -> {:error, {:insecure_directory, dir, type}}
      mode when is_integer(mode) -> {:error, {:insecure_directory, dir, :writable}}
      {:error, _reason} = error -> error
    end
  end

  @spec write_private(String.t(), binary()) :: :ok | {:error, term()}
  defp write_private(path, data) do
    # The containing directory is already private; the file is made 0600
    # before it is renamed to its visible name.
    with :ok <- File.write(path, data, [:exclusive]) do
      File.chmod(path, 0o600)
    end
  end

  @spec probe_uid() :: {:ok, non_neg_integer()} | {:error, term()}
  defp probe_uid do
    probe =
      Path.join(
        System.tmp_dir!(),
        "minga-uid-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    with :ok <- File.write(probe, "", [:exclusive]),
         {:ok, %File.Stat{uid: uid}} <- File.lstat(probe) do
      _ = File.rm(probe)
      {:ok, uid}
    else
      {:error, _reason} = error ->
        _ = File.rm(probe)
        error
    end
  end

  @spec first_error(:ok | {:error, term()}, :ok | {:error, term()}) :: :ok | {:error, term()}
  defp first_error(:ok, result), do: result
  defp first_error({:error, _reason} = error, _result), do: error

  @spec hash(String.t()) :: String.t()
  defp hash(value),
    do: :crypto.hash(:sha256, value) |> Base.hex_encode32(case: :lower, padding: false)
end
