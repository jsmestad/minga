defmodule Minga.Session.StagedDrafts do
  @moduledoc """
  On-disk store for staged agent edits, so they survive a full Minga restart.

  Approved agent edits wait in memory until the user publishes or discards them. This module keeps a durable copy next to the other session files, keyed by project and workspace:

      $XDG_DATA_HOME/minga/staged_drafts/<project key>/<workspace id>/<path key>.json

  The project and path keys are SHA-256 hashes, so file names never reveal project paths. Each draft is one JSON file, written atomically (temporary file, then rename), so a crash leaves either the previous complete draft or the new one. The file carries a `version` field and the project root, workspace id, and path it belongs to; the base and staged bytes are Base64-encoded because file content can be arbitrary bytes. A `base_sha256` fingerprint guards the base against corruption.

  The drafts are user file content. Directories are created with mode `0700` and files with mode `0600`.

  This module only reads and writes files. `MingaAgent.StagedDraftKeeper` decides when to write and delete them.
  """

  alias Minga.Session.StagedDraft

  @format "minga-staged-draft"
  @current_version 1
  @extension ".json"

  @typedoc "Why one stored draft could not be loaded."
  @type lost_reason ::
          :invalid_format
          | :base_fingerprint_mismatch
          | :project_mismatch
          | :invalid_path
          | {:unsupported_version, term()}
          | {:read_failed, term()}

  @typedoc "One loaded draft file: a usable draft, or a lost draft named by its path when known."
  @type entry ::
          {:ok, String.t(), StagedDraft.t()} | {:lost, String.t(), String.t(), lost_reason()}

  @typedoc "Stored drafts of one workspace."
  @type workspace_drafts :: {non_neg_integer(), [entry()]}

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

  @doc "Returns the directory holding one workspace's drafts."
  @spec workspace_dir(String.t(), non_neg_integer(), keyword()) :: String.t()
  def workspace_dir(project_root, workspace_id, opts \\ [])
      when is_binary(project_root) and is_integer(workspace_id) and workspace_id >= 0 do
    Path.join(project_dir(project_root, opts), Integer.to_string(workspace_id))
  end

  @doc "Returns the file that stores the draft for `path`."
  @spec draft_file(String.t(), non_neg_integer(), String.t(), keyword()) :: String.t()
  def draft_file(project_root, workspace_id, path, opts \\ []) when is_binary(path) do
    Path.join(workspace_dir(project_root, workspace_id, opts), hash(path) <> @extension)
  end

  @doc "Atomically writes one draft with private permissions."
  @spec write(String.t(), non_neg_integer(), StagedDraft.t(), keyword()) :: :ok | {:error, term()}
  def write(project_root, workspace_id, %StagedDraft{} = draft, opts \\ []) do
    target = draft_file(project_root, workspace_id, draft.path, opts)
    tmp = "#{target}.#{System.unique_integer([:positive, :monotonic])}.tmp"
    json = JSON.encode!(encode(project_root, workspace_id, draft))

    with :ok <- ensure_private_dirs(project_root, workspace_id, opts),
         :ok <- File.write(tmp, json, [:exclusive]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  @doc "Deletes the stored draft for `path`. A missing file is not an error."
  @spec delete(String.t(), non_neg_integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(project_root, workspace_id, path, opts \\ []) do
    project_root |> draft_file(workspace_id, path, opts) |> remove_file()
  end

  @doc "Deletes every stored draft of one workspace."
  @spec delete_workspace(String.t(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def delete_workspace(project_root, workspace_id, opts \\ []) do
    dir = workspace_dir(project_root, workspace_id, opts)

    case File.rm_rf(dir) do
      {:ok, _removed} ->
        _ = File.rmdir(project_dir(project_root, opts))
        :ok

      {:error, reason, _path} ->
        {:error, reason}
    end
  end

  @doc "Deletes every stored draft of one workspace except the drafts for `keep_paths`."
  @spec prune(String.t(), non_neg_integer(), [String.t()], keyword()) :: :ok | {:error, term()}
  def prune(project_root, workspace_id, keep_paths, opts \\ []) when is_list(keep_paths) do
    dir = workspace_dir(project_root, workspace_id, opts)
    keep = MapSet.new(keep_paths, &(hash(&1) <> @extension))

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(String.ends_with?(&1, @extension) and not MapSet.member?(keep, &1)))
        |> Enum.reduce(:ok, fn name, result ->
          first_error(result, remove_file(Path.join(dir, name)))
        end)

      {:error, :enoent} ->
        :ok

      {:error, _reason} = error ->
        error
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
  Loads every stored draft of a project, grouped by workspace id.

  A draft file that cannot be read or decoded is returned as `{:lost, file, name, reason}`, where `name` is the draft's path when the file still names it. Leftover temporary files from an interrupted write are incomplete and are removed.
  """
  @spec load(String.t(), keyword()) :: [workspace_drafts()]
  def load(project_root, opts \\ []) when is_binary(project_root) do
    dir = project_dir(project_root, opts)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&workspace_id_from_name/1)
        |> Enum.sort()
        |> Enum.map(fn id -> {id, load_workspace(project_root, id, opts)} end)
        |> Enum.reject(fn {_id, entries} -> entries == [] end)

      {:error, _reason} ->
        []
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec project_dir(String.t(), keyword()) :: String.t()
  defp project_dir(project_root, opts), do: Path.join(dir(opts), hash(project_root))

  @spec load_workspace(String.t(), non_neg_integer(), keyword()) :: [entry()]
  defp load_workspace(project_root, workspace_id, opts) do
    dir = workspace_dir(project_root, workspace_id, opts)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(&load_entry(Path.join(dir, &1), project_root, workspace_id))

      {:error, _reason} ->
        []
    end
  end

  @spec load_entry(String.t(), String.t(), non_neg_integer()) :: [entry()]
  defp load_entry(file, project_root, workspace_id) do
    cond do
      String.ends_with?(file, ".tmp") ->
        _ = File.rm(file)
        []

      String.ends_with?(file, @extension) ->
        [read_entry(file, project_root, workspace_id)]

      true ->
        []
    end
  end

  @spec read_entry(String.t(), String.t(), non_neg_integer()) :: entry()
  defp read_entry(file, project_root, workspace_id) do
    with {:ok, data} <- read_file(file),
         {:ok, map} <- decode_json(data) do
      decode(file, map, project_root, workspace_id)
    else
      {:error, reason} -> {:lost, file, Path.basename(file), reason}
    end
  end

  @spec read_file(String.t()) :: {:ok, binary()} | {:error, {:read_failed, term()}}
  defp read_file(file) do
    case File.read(file) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @spec decode_json(binary()) :: {:ok, map()} | {:error, :invalid_format}
  defp decode_json(data) do
    case JSON.decode(data) do
      {:ok, %{} = map} -> {:ok, map}
      _invalid -> {:error, :invalid_format}
    end
  end

  @spec encode(String.t(), non_neg_integer(), StagedDraft.t()) :: map()
  defp encode(project_root, workspace_id, %StagedDraft{} = draft) do
    %{
      "format" => @format,
      "version" => @current_version,
      "project_root" => project_root,
      "workspace_id" => workspace_id,
      "path" => draft.path,
      "base_sha256" => StagedDraft.base_fingerprint(draft),
      "base" => encode_bytes(draft.base),
      "deleted" => draft.content == :deleted,
      "content" => encode_content(draft.content)
    }
  end

  @spec encode_bytes(binary() | nil) :: String.t() | nil
  defp encode_bytes(nil), do: nil
  defp encode_bytes(bytes), do: Base.encode64(bytes)

  @spec encode_content(StagedDraft.content()) :: String.t() | nil
  defp encode_content(:deleted), do: nil
  defp encode_content(bytes), do: Base.encode64(bytes)

  @spec decode(String.t(), map(), String.t(), non_neg_integer()) :: entry()
  defp decode(file, %{"format" => @format, "version" => @current_version} = map, root, id) do
    name = Map.get(map, "path")

    with {:ok, path} <- decode_path(name),
         :ok <- same_owner(map, root, id),
         {:ok, base} <- decode_optional_bytes(Map.get(map, "base")),
         :ok <- verify_base(base, Map.get(map, "base_sha256")),
         {:ok, content} <- decode_content(map) do
      {:ok, file, StagedDraft.new(path, base, content)}
    else
      {:error, reason} -> {:lost, file, lost_name(name, file), reason}
    end
  end

  defp decode(file, %{"format" => @format, "version" => version} = map, _root, _id),
    do: {:lost, file, lost_name(Map.get(map, "path"), file), {:unsupported_version, version}}

  defp decode(file, map, _root, _id),
    do: {:lost, file, lost_name(Map.get(map, "path"), file), :invalid_format}

  @spec lost_name(term(), String.t()) :: String.t()
  defp lost_name(path, _file) when is_binary(path) and path != "", do: path
  defp lost_name(_path, file), do: Path.basename(file)

  @spec decode_path(term()) :: {:ok, String.t()} | {:error, :invalid_path}
  defp decode_path(path) when is_binary(path) and path != "" do
    if Path.type(path) == :relative and ".." not in Path.split(path),
      do: {:ok, path},
      else: {:error, :invalid_path}
  end

  defp decode_path(_path), do: {:error, :invalid_path}

  @spec same_owner(map(), String.t(), non_neg_integer()) :: :ok | {:error, :project_mismatch}
  defp same_owner(%{"project_root" => root, "workspace_id" => id}, root, id), do: :ok
  defp same_owner(_map, _root, _id), do: {:error, :project_mismatch}

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

  @spec workspace_id_from_name(String.t()) :: [non_neg_integer()]
  defp workspace_id_from_name(name) do
    case Integer.parse(name) do
      {id, ""} when id >= 0 -> [id]
      _other -> []
    end
  end

  @spec ensure_private_dirs(String.t(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  defp ensure_private_dirs(project_root, workspace_id, opts) do
    [dir(opts), project_dir(project_root, opts), workspace_dir(project_root, workspace_id, opts)]
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case ensure_private_dir(dir) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec ensure_private_dir(String.t()) :: :ok | {:error, term()}
  defp ensure_private_dir(dir) do
    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, 0o700)
    end
  end

  @spec first_error(:ok | {:error, term()}, :ok | {:error, term()}) :: :ok | {:error, term()}
  defp first_error(:ok, result), do: result
  defp first_error({:error, _reason} = error, _result), do: error

  @spec hash(String.t()) :: String.t()
  defp hash(value),
    do: :crypto.hash(:sha256, value) |> Base.hex_encode32(case: :lower, padding: false)
end
