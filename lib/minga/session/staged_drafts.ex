defmodule Minga.Session.StagedDrafts do
  @moduledoc """
  On-disk store for staged agent edits, so they survive a full Minga restart.

  Approved agent edits wait in memory until the user publishes or discards them. This module keeps a durable copy next to the other session files, keyed by project and by staging view:

      $XDG_DATA_HOME/minga/staged_drafts/<project key>/<view key>/<path key>.json

  The keys are SHA-256 hashes, so file names never reveal project paths. Files are grouped by the identity of the staging view (`MingaAgent.ProjectView` id), not by workspace: two views that claim the same workspace never overwrite or delete each other's drafts. The workspace id is an attribute stored in each draft. A published or discarded view is retired: a content-free `<view key>.retired` tombstone beside its directory marks it until the deletion finishes, so a failed deletion never brings its drafts back. Deleting single drafts (`prune/4`) or a whole view that stays in use (`delete_view/3`) works the same way at draft granularity: a `<view key>.pending` record beside the directory names each draft file whose deletion started, `load/2` skips the named files, and writing a draft under a named file clears its name first.

  Each draft is one JSON file, written atomically (temporary file, then rename), so a crash leaves either the previous complete draft or the new one. The file carries a `version` field. The project root, view id, and path are Base64-encoded, because names can be arbitrary bytes that JSON cannot hold, and so are the base and staged bytes. A `base_sha256` fingerprint guards the base against corruption.

  The drafts are user file content. Every store directory must be a real directory (not a symlink) owned by the current user and not writable by group or others; it is created with mode `0700`, and a directory that fails the check is refused for both writing and loading. Draft files get mode `0600` before they become visible under their final name. Reads accept regular files only and are bounded by `max_draft_bytes/1`. A draft above `max_file_bytes/1` is never saved; `write_lost/6` replaces its stored copy with a content-free marker, so the next start reports it as lost instead of restoring an older version.

  Several Minga instances can share the store. Each view directory holds an owner record naming the instance that saves it (`claim_view_dir/4`): its OS process id and that process's start time, so a reused process id never looks like the old owner. An instance only writes, restores, or deletes a view it has claimed; a view whose owner is still running is left alone, and the claim of an owner that is gone is taken over.

  This module only reads and writes files. `MingaAgent.StagedDraftKeeper` decides when to write and delete them.
  """

  import Bitwise, only: [band: 2]

  alias Minga.SecureFile
  alias Minga.Session.StagedDraft

  @format "minga-staged-draft"
  @current_version 1
  @extension ".json"
  @retired ".retired"
  @pending ".pending"
  @max_pending_bytes 1024 * 1024
  @owner_file "owner"
  @aside ".aside"
  @owner_format "minga-staged-draft-owner"
  @max_owner_bytes 4096
  @claim_attempts 3

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

  @typedoc """
  The stored drafts of one staging view.

  A retired view (`retired: true`) was published or discarded, or holds only drafts whose deletion is pending, and its deletion has not finished. It has no entries and must never be offered again; its directory is removed with `retire_view_dir/1`.
  """
  @type stored_view :: %{
          dir: String.t(),
          view_id: String.t(),
          workspace_id: non_neg_integer() | nil,
          entries: [entry()],
          retired: boolean()
        }

  @typedoc "The Minga instance that saves a view: its OS process id and that process's start time."
  @type owner :: %{os_pid: pos_integer(), started: String.t()}

  @typedoc "Answers whether another instance's owner record names a process that is still running."
  @type owner_alive? :: (owner() -> boolean())

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

    # The pending name is cleared only once the new draft is ready to replace
    # the old file, so a failed write leaves the old file recorded as pending.
    with :ok <- ensure_private_dirs(project_root, view_id, opts),
         :ok <- write_private(tmp, json),
         :ok <- unmark_pending(Path.dirname(target), Path.basename(target)),
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

  A draft whose removal fails is recorded as pending deletion, so `load/2` never returns it, and the next prune retries it. Only the owner of the view (the process that writes its drafts) may call this, and never while one of its own writes is in progress: temporary files are removed here, not when loading, because a temporary file can belong to a write that is still running.
  """
  @spec prune(String.t(), String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def prune(project_root, view_id, keep_paths, opts \\ []) when is_list(keep_paths) do
    dir = view_dir(project_root, view_id, opts)
    keep = MapSet.new(keep_paths, &(hash(&1) <> @extension))

    case File.ls(dir) do
      {:ok, names} ->
        stale = Enum.filter(names, &stale_name?(&1, keep))
        remove_drafts(dir, stale)

      {:error, :enoent} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  # Stale drafts are recorded as pending deletion before they are removed, so
  # a draft whose removal fails is never loaded again. The record is only a
  # safeguard: the removal's result is what decides whether pruning is done.
  @spec remove_drafts(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp remove_drafts(_dir, []), do: :ok

  defp remove_drafts(dir, names) do
    _ = mark_pending(dir, Enum.filter(names, &String.ends_with?(&1, @extension)))

    removed =
      Enum.reduce(names, :ok, fn name, result ->
        first_error(result, remove_file(Path.join(dir, name)))
      end)

    _ = settle_pending(dir)
    removed
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
  def remove_view_dir(%{dir: dir}), do: remove_dir(dir)

  @doc """
  Claims the view stored in `dir` (from `view_dir/3`, or a loaded view) for `owner`.

  Returns `:ok` when `owner` already holds the claim, when the view has no owner, or when its owner is gone (`alive?` returns `false`, or the record is unreadable). Returns `{:error, :owned}` while another instance that is still running holds it. The record is created atomically (hard link of a complete file), and a stale record is moved aside (`owner.<n>.aside`, a name `prune/4` never removes) before it is replaced, so two instances that take over the same stale view never both succeed. A moved record that turns out to be another instance's fresh claim is put back; if that fails, it stays aside, and every later claim yields to it while its owner runs.

  `opts[:link]` replaces `File.ln/2`, for tests.
  """
  @spec claim_view_dir(String.t(), owner(), owner_alive?(), keyword()) ::
          :ok | {:error, :owned | term()}
  def claim_view_dir(dir, %{os_pid: _, started: _} = owner, alive?, opts \\ [])
      when is_binary(dir) and is_function(alive?, 1) do
    with {:ok, uid} <- owner_uid(opts),
         :ok <- File.mkdir_p(Path.dirname(dir(opts))),
         :ok <- all_ok([dir(opts), Path.dirname(dir), dir], &create_private(&1, uid)) do
      context = %{
        dir: dir,
        file: Path.join(dir, @owner_file),
        owner: owner,
        alive?: alive?,
        link: Keyword.get(opts, :link, &File.ln/2)
      }

      claim(context, @claim_attempts)
    end
  end

  @doc """
  Checks, without creating anything, that `owner` may still change the view stored in `dir`.

  Returns `:ok` when `owner` holds the claim, when the view has no owner record, or when its recorded owner is gone; `{:error, :owned}` when another instance that is still running holds it. Call it before deleting files of a view claimed earlier: another instance may have taken the view over since.
  """
  @spec check_view_claim(String.t(), owner(), owner_alive?()) :: :ok | {:error, :owned | term()}
  def check_view_claim(dir, %{os_pid: _, started: _} = owner, alive?)
      when is_binary(dir) and is_function(alive?, 1) do
    case read_owner(Path.join(dir, @owner_file)) do
      {:ok, {:owner, ^owner, _bytes}} -> :ok
      {:ok, {:owner, other, _bytes}} -> if alive?.(other), do: {:error, :owned}, else: :ok
      {:ok, {:invalid, _content}} -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Gives up `owner`'s claim on the view stored in `dir`, leaving another owner's claim alone."
  @spec release_view_dir(String.t(), owner()) :: :ok | {:error, term()}
  def release_view_dir(dir, %{os_pid: _, started: _} = owner) when is_binary(dir) do
    file = Path.join(dir, @owner_file)

    case read_owner(file) do
      {:ok, {:owner, ^owner, _bytes}} -> remove_file(file)
      {:ok, _other} -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @typep claim_context :: %{
           dir: String.t(),
           file: String.t(),
           owner: owner(),
           alive?: owner_alive?(),
           link: (String.t(), String.t() -> :ok | {:error, term()})
         }

  @spec claim(claim_context(), non_neg_integer()) :: :ok | {:error, :owned | term()}
  defp claim(_context, 0), do: {:error, :claim_contended}

  defp claim(context, attempts) do
    case create_owner(context) do
      :ok -> settle_asides(context)
      {:error, :eexist} -> claim_existing(context, attempts)
      {:error, :enoent} -> claim(context, attempts - 1)
      {:error, _reason} = error -> error
    end
  end

  @spec claim_existing(claim_context(), pos_integer()) :: :ok | {:error, :owned | term()}
  defp claim_existing(%{owner: owner} = context, attempts) do
    case read_owner(context.file) do
      {:ok, {:owner, ^owner, _bytes}} ->
        :ok

      {:ok, {:owner, other, _bytes} = record} ->
        if context.alive?.(other),
          do: {:error, :owned},
          else: take_over(context, record, attempts)

      {:ok, {:invalid, _content} = record} ->
        take_over(context, record, attempts)

      {:error, :enoent} ->
        claim(context, attempts - 1)

      {:error, _reason} = error ->
        error
    end
  end

  # Moves the stale record aside, then claims again. If another instance
  # replaced the stale record first, the moved file is that instance's fresh
  # claim: it is put back, and the view stays theirs. A record that cannot be
  # put back is never deleted; it stays aside for `settle_asides/1`.
  @spec take_over(claim_context(), owner_record(), pos_integer()) ::
          :ok | {:error, :owned | term()}
  defp take_over(%{file: file} = context, stale, attempts) do
    aside = "#{file}.#{System.unique_integer([:positive, :monotonic])}#{@aside}"

    case File.rename(file, aside) do
      :ok ->
        if read_owner(aside) == {:ok, stale} do
          _ = File.rm(aside)
          claim(context, attempts - 1)
        else
          put_back(context, aside)
        end

      {:error, :enoent} ->
        claim(context, attempts - 1)

      {:error, _reason} = error ->
        error
    end
  end

  @spec put_back(claim_context(), String.t()) :: {:error, :owned}
  defp put_back(context, aside) do
    case context.link.(aside, context.file) do
      :ok -> _ = File.rm(aside)
      {:error, _reason} -> :ok
    end

    {:error, :owned}
  end

  # A new claim yields to a record left aside by a failed put-back while that
  # record's owner runs. Aside records that are this owner's, unreadable, or
  # of an owner that is gone are removed.
  @spec settle_asides(claim_context()) :: :ok | {:error, :owned}
  defp settle_asides(%{dir: dir} = context) do
    names =
      case File.ls(dir) do
        {:ok, names} -> Enum.filter(names, &String.ends_with?(&1, @aside))
        {:error, _reason} -> []
      end

    Enum.reduce_while(names, :ok, fn name, :ok ->
      case settle_aside(context, Path.join(dir, name)) do
        :ok -> {:cont, :ok}
        {:error, :owned} = owned -> {:halt, owned}
      end
    end)
  end

  @spec settle_aside(claim_context(), String.t()) :: :ok | {:error, :owned}
  defp settle_aside(%{owner: owner} = context, aside) do
    case read_owner(aside) do
      {:ok, {:owner, ^owner, _bytes}} ->
        _ = File.rm(aside)
        :ok

      {:ok, {:owner, other, _bytes}} ->
        if context.alive?.(other), do: yield(context, aside), else: remove_aside(aside)

      {:ok, {:invalid, _content}} ->
        remove_aside(aside)

      {:error, _reason} ->
        :ok
    end
  end

  @spec remove_aside(String.t()) :: :ok
  defp remove_aside(aside) do
    _ = File.rm(aside)
    :ok
  end

  # Gives the just-created claim back to the running owner of `aside`.
  @spec yield(claim_context(), String.t()) :: {:error, :owned}
  defp yield(context, aside) do
    _ = File.rm(context.file)
    put_back(context, aside)
  end

  # A hard link publishes a complete record and fails when one exists.
  @spec create_owner(claim_context()) :: :ok | {:error, term()}
  defp create_owner(%{file: file, owner: %{os_pid: os_pid, started: started}} = context) do
    tmp = "#{file}.#{System.unique_integer([:positive, :monotonic])}.tmp"

    json =
      JSON.encode!(%{
        "format" => @owner_format,
        "version" => @current_version,
        "os_pid" => os_pid,
        "started" => started
      })

    result =
      with :ok <- write_private(tmp, json) do
        context.link.(tmp, file)
      end

    _ = File.rm(tmp)
    result
  end

  # An owner record as found on disk. Its bytes (or why it is unusable)
  # identify it when it is moved aside during a takeover.
  @typep owner_record :: {:owner, owner(), binary()} | {:invalid, binary() | atom()}

  @spec read_owner(String.t()) :: {:ok, owner_record()} | {:error, term()}
  defp read_owner(file) do
    case SecureFile.read(file, @max_owner_bytes) do
      {:ok, bytes} -> {:ok, decode_owner_record(bytes)}
      {:error, {:file_read_failed, _path, reason}} -> {:error, reason}
      # The reason without the path, which changes when the file is moved.
      {:error, unusable} -> {:ok, {:invalid, elem(unusable, 0)}}
    end
  end

  @spec decode_owner_record(binary()) :: owner_record()
  defp decode_owner_record(bytes) do
    case JSON.decode(bytes) do
      {:ok,
       %{
         "format" => @owner_format,
         "version" => @current_version,
         "os_pid" => os_pid,
         "started" => started
       }}
      when is_integer(os_pid) and os_pid > 0 and is_binary(started) ->
        {:owner, %{os_pid: os_pid, started: started}, bytes}

      _invalid ->
        {:invalid, bytes}
    end
  end

  @doc """
  Deletes every stored draft of a view that is published or discarded, so its drafts are never offered again.

  A content-free tombstone next to the view directory (`<view key>.retired`) is written first and removed last. If the deletion fails, the tombstone survives a restart, so `load/2` reports the view as retired instead of offering its drafts. Retry with `retire_view_dir/1`.
  """
  @spec retire_view(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def retire_view(project_root, view_id, opts \\ []) do
    project_root |> view_dir(view_id, opts) |> retire_view_dir()
  end

  @doc "Finishes retiring the view stored in `dir` (from `view_dir/3`, or a loaded view). A view that is already gone is not an error."
  @spec retire_view_dir(String.t()) :: :ok | {:error, term()}
  def retire_view_dir(dir) when is_binary(dir) do
    tombstone = dir <> @retired

    case File.lstat(dir) do
      {:error, :enoent} ->
        with :ok <- remove_file(pending_file(dir)), do: remove_file(tombstone)

      _exists ->
        # A failed tombstone only matters if the deletion fails too; the
        # deletion's result decides whether the view is still pending.
        _ = mark_retired(tombstone)

        with :ok <- remove_dir(dir) do
          remove_file(tombstone)
        end
    end
  end

  @spec mark_retired(String.t()) :: :ok | {:error, term()}
  defp mark_retired(tombstone) do
    case File.write(tombstone, "", [:exclusive]) do
      result when result in [:ok, {:error, :eexist}] -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Deletes every stored draft of one view.

  The drafts are recorded as pending deletion first, so a deletion that fails part way never brings them back at the next `load/2`.

  The project directory is left in place, even when empty: removing it could race with another writer (another view, or another Minga instance) that has just checked it and is about to create its own view directory inside it.
  """
  @spec delete_view(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete_view(project_root, view_id, opts \\ []) do
    dir = view_dir(project_root, view_id, opts)

    case File.ls(dir) do
      {:ok, names} ->
        _ = mark_pending(dir, Enum.filter(names, &String.ends_with?(&1, @extension)))

      {:error, _reason} ->
        :ok
    end

    remove_dir(dir)
  end

  # The pending-deletion record beside the directory goes last, once nothing
  # it names is left.
  @spec remove_dir(String.t()) :: :ok | {:error, term()}
  defp remove_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _removed} -> remove_file(pending_file(dir))
      {:error, reason, _path} -> {:error, reason}
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

  A draft that can never be restored is returned as `{:lost, file, name, reason}`; one that cannot be read now is `{:retained, file, name, reason}`. A view with a retirement tombstone is returned with `retired: true` and no entries; its drafts are not read. A draft recorded as pending deletion is skipped, and a view left with only such drafts is returned as retired; if that record cannot be read, every draft of its view is retained. `name` is the draft's path when the file still names it. Temporary files are skipped and left alone: one may belong to a write that is still in progress (`prune/4` removes leftovers for the view's owner). Returns `{:error, reason}` without reading anything when a store directory fails the privacy check.
  """
  @spec load(String.t(), keyword()) :: {:ok, [stored_view()]} | {:error, term()}
  def load(project_root, opts \\ []) when is_binary(project_root) do
    project = project_dir(project_root, opts)

    with {:ok, uid} <- owner_uid(opts),
         :ok <- verify_existing_private(dir(opts), uid),
         :ok <- verify_existing_private(project, uid),
         {:ok, names} <- list_dir(project) do
      {retired, live} = split_retired(names)
      dirs = live |> Enum.sort() |> Enum.map(&Path.join(project, &1))

      with :ok <- all_ok(dirs, &verify_private(&1, uid)) do
        loaded = Enum.flat_map(dirs, &List.wrap(load_view(&1, project_root, opts)))
        {:ok, Enum.map(retired, &retired_view(Path.join(project, &1))) ++ loaded}
      end
    else
      :absent -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec project_dir(String.t(), keyword()) :: String.t()
  defp project_dir(project_root, opts), do: Path.join(dir(opts), hash(project_root))

  # Splits a project directory's names into retired view keys (with or
  # without a remaining view directory) and the live view directories.
  @spec split_retired([String.t()]) :: {[String.t()], [String.t()]}
  defp split_retired(names) do
    retired =
      for name <- names, String.ends_with?(name, @retired), into: MapSet.new() do
        String.replace_suffix(name, @retired, "")
      end

    live = Enum.filter(names, &(view_key?(&1) and not MapSet.member?(retired, &1)))
    {retired |> MapSet.to_list() |> Enum.sort(), live}
  end

  # View directories are named by a hash key without a dot. Tombstones,
  # pending-deletion records, and their temporary files beside them have one.
  @spec view_key?(String.t()) :: boolean()
  defp view_key?(name), do: not String.contains?(name, ".")

  @spec retired_view(String.t()) :: stored_view()
  defp retired_view(dir),
    do: %{dir: dir, view_id: "", workspace_id: nil, entries: [], retired: true}

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
    case File.ls(dir) do
      {:ok, names} -> load_names(dir, Enum.sort(names), project_root, opts)
      {:error, _reason} -> nil
    end
  end

  # The view id and workspace id come from the decoded drafts; a view whose
  # drafts are all unreadable is still reported so its losses are named.
  @spec stored_view(String.t(), [{entry(), String.t() | nil, non_neg_integer() | nil}, ...]) ::
          stored_view()
  defp stored_view(dir, decoded) do
    owner = Enum.find_value(decoded, fn {_entry, view_id, ws} -> view_id && {view_id, ws} end)
    {view_id, workspace_id} = owner || {"", nil}

    %{
      dir: dir,
      view_id: view_id,
      workspace_id: workspace_id,
      entries: Enum.map(decoded, &elem(&1, 0)),
      retired: false
    }
  end

  # A draft whose deletion is pending is never loaded. A view that holds only
  # such drafts is reported as retired, so its deletion is finished. When the
  # record of pending deletions cannot be read, every draft of the view is
  # retained, so the view waits for a later start instead of offering a
  # deleted draft.
  @spec load_names(String.t(), [String.t()], String.t(), keyword()) :: stored_view() | nil
  defp load_names(dir, names, project_root, opts) do
    case read_pending(dir) do
      {:ok, pending} ->
        {skipped, kept} = Enum.split_with(names, &MapSet.member?(pending, &1))

        case {Enum.flat_map(kept, &load_entry(Path.join(dir, &1), project_root, opts)), skipped} do
          {[], []} -> nil
          {[], _pending_only} -> retired_view(dir)
          {entries, _skipped} -> stored_view(dir, entries)
        end

      {:error, reason} ->
        retained =
          for name <- names, String.ends_with?(name, @extension) do
            {{:retained, Path.join(dir, name), name, {:read_failed, reason}}, nil, nil}
          end

        if retained == [], do: nil, else: stored_view(dir, retained)
    end
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

  # ── Pending deletions ───────────────────────────────────────────────────
  #
  # `<view key>.pending` beside a view directory names the draft files of that
  # view whose deletion was started but may not have finished. It sits outside
  # the view directory, so it can be written when that directory cannot. It
  # holds one draft file name (a hash) per line and no content or paths.

  @spec pending_file(String.t()) :: String.t()
  defp pending_file(dir), do: dir <> @pending

  @spec read_pending(String.t()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  defp read_pending(dir) do
    case SecureFile.read(pending_file(dir), @max_pending_bytes) do
      {:ok, data} -> {:ok, data |> String.split("\n", trim: true) |> MapSet.new()}
      {:error, {:file_read_failed, _path, :enoent}} -> {:ok, MapSet.new()}
      {:error, {:file_read_failed, _path, reason}} -> {:error, {:pending_record, reason}}
      {:error, reason} -> {:error, {:pending_record, reason}}
    end
  end

  @spec mark_pending(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp mark_pending(_dir, []), do: :ok

  defp mark_pending(dir, names) do
    with {:ok, pending} <- read_pending(dir) do
      write_pending(dir, MapSet.union(pending, MapSet.new(names)))
    end
  end

  # A draft written again under a pending name is staged again: the name is
  # cleared first, and the write fails when it cannot be cleared.
  @spec unmark_pending(String.t(), String.t()) :: :ok | {:error, term()}
  defp unmark_pending(dir, name) do
    with {:ok, pending} <- read_pending(dir) do
      if MapSet.member?(pending, name),
        do: write_pending(dir, MapSet.delete(pending, name)),
        else: :ok
    end
  end

  # Names whose files are gone are dropped from the record.
  @spec settle_pending(String.t()) :: :ok | {:error, term()}
  defp settle_pending(dir) do
    with {:ok, pending} <- read_pending(dir) do
      remaining = MapSet.filter(pending, &match?({:ok, _}, File.lstat(Path.join(dir, &1))))
      if remaining == pending, do: :ok, else: write_pending(dir, remaining)
    end
  end

  @spec write_pending(String.t(), MapSet.t(String.t())) :: :ok | {:error, term()}
  defp write_pending(dir, pending) do
    target = pending_file(dir)

    if MapSet.size(pending) == 0 do
      remove_file(target)
    else
      tmp = "#{target}.#{System.unique_integer([:positive, :monotonic])}.tmp"
      data = pending |> Enum.sort() |> Enum.map_join("", &(&1 <> "\n"))

      with :ok <- write_private(tmp, data),
           :ok <- File.rename(tmp, target) do
        :ok
      else
        {:error, _reason} = error ->
          _ = File.rm(tmp)
          error
      end
    end
  end

  @spec hash(String.t()) :: String.t()
  defp hash(value),
    do: :crypto.hash(:sha256, value) |> Base.hex_encode32(case: :lower, padding: false)
end
