defmodule MingaAgent.OAuth.Store do
  @moduledoc """
  Coordinates Minga's OAuth file operations within one BEAM node.

  ReqLLM still performs token refresh. Hold the same guard for its entire read, refresh and publish operation as for local install and revoke. Local writes fail promptly if a refresh is in flight, so the editor or Session does not wait on provider I/O.
  """

  alias Minga.Buffer.Persistence.SystemFileSystem

  @max_symlink_depth 40

  @doc "Installs provider entries atomically without changing other providers."
  @spec install(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def install(path, entries, opts) do
    file_system = Keyword.get(opts, :file_system, SystemFileSystem)

    with {:ok, target} <- file_target(path),
         :ok <- file_system.mkdir_p(Path.dirname(target), opts) do
      with_directory_lock(target, 0, fn -> install_entries(target, entries, file_system, opts) end)
    end
  end

  @spec install_entries(String.t(), map(), module(), keyword()) :: :ok | {:error, term()}
  defp install_entries(target, entries, file_system, opts) do
    with {:ok, existing} <- read(target) do
      replace(target, Map.merge(existing, entries), file_system, opts)
    end
  end

  @doc "Removes a provider entry if present, without creating a missing file."
  @spec remove(String.t(), String.t()) :: :ok | {:error, term()}
  def remove(path, provider) do
    with {:ok, target} <- file_target(path),
         {:ok, _file} <- File.stat(target) do
      with_directory_lock(target, 0, fn -> remove_entry(target, provider) end)
    else
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Resolves through ReqLLM without permitting a concurrent Minga write."
  @spec resolve(String.t(), keyword()) ::
          {:ok, ReqLLM.OAuth.resolved_credential()} | {:error, term()}
  def resolve(path, opts \\ []) do
    configured = Path.absname(path)

    with {:ok, target} <- file_target(configured) do
      with_directory_lock(target, :infinity, fn -> resolve_target(configured, target, opts) end)
    end
  end

  @spec resolve_target(String.t(), String.t(), keyword()) ::
          {:ok, ReqLLM.OAuth.resolved_credential()} | {:error, :oauth_resolution_failed}
  defp resolve_target(configured, target, opts) do
    case ReqLLM.OAuth.resolve(:openai_codex, Keyword.put(opts, :oauth_file, target)) do
      {:ok, %{oauth_file: ^target} = credential} -> {:ok, %{credential | oauth_file: configured}}
      _unresolved -> {:error, :oauth_resolution_failed}
    end
  end

  @spec with_directory_lock(String.t(), non_neg_integer() | :infinity, (-> result)) ::
          result | {:error, term()}
        when result: var
  defp with_directory_lock(path, retries, run) do
    # A directory identity is stable across replacement and also covers case-insensitive names and path aliases.
    case File.stat(Path.dirname(path)) do
      {:ok, %File.Stat{type: :directory} = directory} ->
        resource = {__MODULE__, directory.major_device, directory.minor_device, directory.inode}
        run_locked(resource, retries, run)

      {:ok, _not_directory} ->
        {:error, :enotdir}

      {:error, _reason} = error ->
        error
    end
  end

  @spec run_locked(tuple(), non_neg_integer() | :infinity, (-> result)) ::
          result | {:error, :oauth_file_busy}
        when result: var
  defp run_locked(resource, retries, run) do
    case :global.trans({resource, self()}, run, [node()], retries) do
      :aborted -> {:error, :oauth_file_busy}
      result -> result
    end
  end

  @spec remove_entry(String.t(), String.t()) :: :ok | {:error, term()}
  defp remove_entry(target, provider) do
    with {:ok, existing} <- read(target) do
      case Map.delete(existing, provider) do
        ^existing -> :ok
        updated -> replace(target, updated, SystemFileSystem, [])
      end
    end
  end

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  defp read(path) do
    case File.read(path) do
      {:ok, ""} -> {:ok, %{}}
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> {:ok, %{}}
      {:error, _reason} = error -> error
    end
  end

  @spec decode(String.t()) :: {:ok, map()} | {:error, :invalid_oauth_file}
  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _invalid -> {:error, :invalid_oauth_file}
    end
  end

  @spec replace(String.t(), map(), module(), keyword()) :: :ok | {:error, term()}
  defp replace(target, entries, file_system, opts) do
    contents = IO.iodata_to_binary(:json.format(entries))
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    sibling = target <> ".minga-save-" <> suffix <> ".tmp"

    # The system file boundary restricts an exclusive sibling to 0600 before returning the handle.
    with {:ok, device} <- file_system.open_exclusive(sibling, opts) do
      prepared =
        with :ok <- file_system.write(device, contents, opts), do: file_system.flush(device, opts)

      closed = file_system.close(device, opts)

      case publish(sibling, target, prepared, closed, file_system, opts) do
        :ok ->
          :ok

        {:error, _reason} = error ->
          file_system.remove(sibling, opts)
          error
      end
    end
  end

  @spec publish(
          String.t(),
          String.t(),
          :ok | {:error, term()},
          :ok | {:error, term()},
          module(),
          keyword()
        ) ::
          :ok | {:error, term()}
  defp publish(sibling, target, :ok, :ok, file_system, opts),
    do: file_system.rename(sibling, target, opts)

  defp publish(_sibling, _target, {:error, _reason} = error, _closed, _file_system, _opts),
    do: error

  defp publish(_sibling, _target, :ok, {:error, _reason} = error, _file_system, _opts), do: error

  @spec file_target(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp file_target(path) do
    [anchor | parts] = Path.split(Path.absname(path))
    walk(parts, anchor, 0)
  end

  @spec walk([String.t()], String.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  defp walk([], current, _depth), do: {:ok, current}
  defp walk(["." | rest], current, depth), do: walk(rest, current, depth)
  defp walk([".." | rest], current, depth), do: walk(rest, Path.dirname(current), depth)

  defp walk([part | rest], current, depth) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} -> follow(candidate, current, rest, depth)
      {:ok, %File.Stat{type: :directory}} -> walk(rest, candidate, depth)
      {:ok, %File.Stat{type: :regular}} when rest == [] -> {:ok, candidate}
      {:ok, %File.Stat{}} -> {:error, :invalid_oauth_path}
      {:error, :enoent} -> missing_target(candidate, rest)
      {:error, _reason} = error -> error
    end
  end

  @spec follow(String.t(), String.t(), [String.t()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  defp follow(_candidate, _current, _rest, @max_symlink_depth), do: {:error, :eloop}

  defp follow(candidate, current, rest, depth) do
    with {:ok, link} <- File.read_link(candidate) do
      case Path.split(link) do
        ["/" | parts] -> walk(parts ++ rest, "/", depth + 1)
        parts -> walk(parts ++ rest, current, depth + 1)
      end
    end
  end

  @spec missing_target(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, :enoent}
  defp missing_target(current, rest) do
    if ".." in rest, do: {:error, :enoent}, else: {:ok, Path.join([current | rest])}
  end
end
