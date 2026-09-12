defmodule Minga.Buffer.Persistence.LocalWriter do
  @moduledoc """
  Owns the complete atomic commit protocol for one local buffer save.

  The workflow resolves a final symlink, creates a unique sibling temporary
  file, writes the complete content, applies owner/group/mode metadata, flushes
  it, closes it, and only then commits. Existing targets use atomic rename.
  Exclusive creation uses a same-directory hard link, which cannot replace a
  target that appeared after save-intent validation.

  A successful commit remains successful when post-commit temporary cleanup
  fails. That failure is logged because the new destination is already
  authoritative and the Buffer must advance its saved revision.
  """

  alias Minga.Buffer.Persistence
  alias Minga.Buffer.Persistence.SystemFileSystem

  @max_symlink_depth 40

  @doc "Writes local content through the complete atomic save workflow."
  @spec write(String.t(), binary(), Persistence.write_policy(), module(), keyword()) ::
          :ok | {:error, term()}
  def write(path, content, policy, file_system \\ SystemFileSystem, opts \\ [])
      when is_binary(path) and is_binary(content) and is_atom(file_system) and is_list(opts) do
    with {:ok, target_path} <- resolve_final_symlink(file_system, path, opts),
         {:ok, target_metadata} <- existing_metadata(file_system, target_path, opts),
         :ok <- file_system.mkdir_p(Path.dirname(target_path), opts),
         temporary_path = unique_temporary_path(target_path),
         {:ok, device} <- file_system.open_exclusive(temporary_path, opts) do
      write_open_transaction(
        file_system,
        device,
        temporary_path,
        target_path,
        target_metadata,
        content,
        policy,
        opts
      )
    end
  end

  @spec write_open_transaction(
          module(),
          term(),
          String.t(),
          String.t(),
          File.Stat.t() | nil,
          binary(),
          Persistence.write_policy(),
          keyword()
        ) :: :ok | {:error, term()}
  defp write_open_transaction(
         file_system,
         device,
         temporary_path,
         target_path,
         target_metadata,
         content,
         policy,
         opts
       ) do
    prepared =
      with :ok <- file_system.write(device, content, opts),
           :ok <- file_system.preserve_metadata(temporary_path, target_metadata, opts) do
        file_system.flush(device, opts)
      end

    closed = file_system.close(device, opts)

    commit_result =
      maybe_commit(prepared, closed, file_system, temporary_path, target_path, policy, opts)

    cleanup_result = remove_temporary(file_system, temporary_path, opts)
    finish(commit_result, cleanup_result, temporary_path, opts)
  end

  @spec maybe_commit(
          :ok | {:error, term()},
          :ok | {:error, term()},
          module(),
          String.t(),
          String.t(),
          Persistence.write_policy(),
          keyword()
        ) :: :ok | {:error, term()}
  defp maybe_commit(:ok, :ok, file_system, temporary, target, :replace, opts) do
    file_system.rename(temporary, target, opts)
  end

  defp maybe_commit(:ok, :ok, file_system, temporary, target, :exclusive_create, opts) do
    file_system.link(temporary, target, opts)
  end

  defp maybe_commit(
         {:error, _reason} = error,
         :ok,
         _fs,
         _temporary,
         _target,
         _policy,
         _opts
       ),
       do: error

  defp maybe_commit(
         {:error, reason},
         {:error, close_reason},
         _fs,
         _temporary,
         _target,
         _policy,
         _opts
       ),
       do: {:error, {reason, {:close_failed, close_reason}}}

  defp maybe_commit(
         :ok,
         {:error, _reason} = error,
         _fs,
         _temporary,
         _target,
         _policy,
         _opts
       ),
       do: error

  @spec finish(:ok | {:error, term()}, :ok | {:error, term()}, String.t(), keyword()) ::
          :ok | {:error, term()}
  defp finish(:ok, :ok, _temporary, _opts), do: :ok

  defp finish(:ok, {:error, reason}, temporary, _opts) do
    Minga.Log.warning(
      :editor,
      "Local save committed but could not remove temporary file #{temporary}: #{inspect(reason)}"
    )

    :ok
  end

  defp finish({:error, _reason} = error, :ok, _temporary, _opts), do: error

  defp finish({:error, reason}, {:error, cleanup_reason}, _temporary, _opts) do
    {:error, {reason, {:cleanup_failed, cleanup_reason}}}
  end

  @spec resolve_final_symlink(module(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_final_symlink(file_system, path, opts) do
    resolve_final_symlink(file_system, Path.expand(path), 0, opts)
  end

  @spec resolve_final_symlink(module(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_final_symlink(_file_system, _path, @max_symlink_depth, _opts),
    do: {:error, :eloop}

  defp resolve_final_symlink(file_system, path, depth, opts) do
    case file_system.lstat(path, opts) do
      {:ok, %{type: :symlink}} -> resolve_link(file_system, path, depth, opts)
      {:ok, _stat} -> {:ok, path}
      {:error, :enoent} -> {:ok, path}
      {:error, _reason} = error -> error
    end
  end

  @spec resolve_link(module(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_link(file_system, path, depth, opts) do
    case file_system.read_link(path, opts) do
      {:ok, link} ->
        resolved =
          if Path.type(link) == :absolute, do: link, else: Path.join(Path.dirname(path), link)

        resolve_final_symlink(file_system, Path.expand(resolved), depth + 1, opts)

      {:error, _reason} = error ->
        error
    end
  end

  @spec existing_metadata(module(), String.t(), keyword()) ::
          {:ok, File.Stat.t() | nil} | {:error, term()}
  defp existing_metadata(file_system, path, opts) do
    case file_system.stat(path, opts) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @spec unique_temporary_path(String.t()) :: String.t()
  defp unique_temporary_path(target) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Path.join(Path.dirname(target), ".#{Path.basename(target)}.minga-save-#{suffix}.tmp")
  end

  @spec remove_temporary(module(), String.t(), keyword()) :: :ok | {:error, term()}
  defp remove_temporary(file_system, path, opts) do
    case file_system.remove(path, opts) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
