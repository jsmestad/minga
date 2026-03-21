defmodule Minga.Agent.Tools.WriteFile do
  @moduledoc """
  Writes content to a file, creating parent directories as needed.

  Routes through `Buffer.Server.replace_content/2` when a buffer is open
  for the file (undoable, immediate viewport update, no FileWatcher noise).
  Falls back to filesystem I/O when no buffer exists (including new file
  creation).
  """

  alias Minga.Buffer.Server, as: BufferServer

  @doc """
  Writes `content` to the file at `path`.

  Creates any missing parent directories. Overwrites the file if it already
  exists. Returns `{:ok, message}` on success or `{:error, reason}` on failure.
  """
  @spec execute(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, content) when is_binary(path) and is_binary(content) do
    case BufferServer.pid_for_path(path) do
      {:ok, pid} -> execute_via_buffer(pid, path, content)
      :not_found -> execute_via_filesystem(path, content)
    end
  end

  @spec execute_via_buffer(pid(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_via_buffer(pid, path, content) do
    case BufferServer.replace_content(pid, content) do
      :ok -> {:ok, "wrote #{byte_size(content)} bytes to #{path} (via buffer)"}
      {:error, :read_only} -> {:error, "buffer is read-only: #{path}"}
    end
  catch
    # Buffer process died between pid_for_path and the call
    :exit, _ -> {:error, "buffer process died for #{path}"}
  end

  @spec execute_via_filesystem(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_via_filesystem(path, content) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok ->
        case File.write(path, content) do
          :ok ->
            {:ok, "wrote #{byte_size(content)} bytes to #{path}"}

          {:error, reason} ->
            {:error, "failed to write #{path}: #{reason}"}
        end

      {:error, reason} ->
        {:error, "failed to create directory for #{path}: #{reason}"}
    end
  end
end
