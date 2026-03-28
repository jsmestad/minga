defmodule Minga.Agent.Tools.WriteFile do
  @moduledoc """
  Writes content to a file, creating parent directories as needed.

  Routes through `Buffer.Server.replace_content/2` when a buffer is open
  for the file (undoable, immediate viewport update, no FileWatcher noise).
  Falls back to filesystem I/O when no buffer exists (including new file
  creation).
  """

  alias Minga.Buffer

  @doc """
  Writes `content` to the file at `path`.

  Creates any missing parent directories. For existing files with an open
  buffer, routes through `replace_content`. For new files, writes to disk
  first then opens a buffer so the file appears in the buffer list.
  Falls back to filesystem-only when the Editor is not running.

  Returns `{:ok, message}` on success or `{:error, reason}` on failure.
  """
  @spec execute(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, content) when is_binary(path) and is_binary(content) do
    case Buffer.pid_for_path(path) do
      {:ok, pid} ->
        # Buffer already open, replace content in-memory
        execute_via_buffer(pid, path, content)

      :not_found ->
        # Write to disk first (handles new file creation + parent dirs),
        # then open a buffer so the user gets visibility and undo.
        case execute_via_filesystem(path, content) do
          {:ok, msg} ->
            open_buffer_for_written_file(path)
            {:ok, msg}

          error ->
            error
        end
    end
  end

  @spec execute_via_buffer(pid(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_via_buffer(pid, path, content) do
    case Buffer.replace_content(pid, content, :agent) do
      :ok -> {:ok, "wrote #{byte_size(content)} bytes to #{path} (via buffer)"}
      {:error, :read_only} -> {:error, "buffer is read-only: #{path}"}
    end
  catch
    # Buffer process died between pid_for_path and the call
    :exit, _ -> {:error, "buffer process died for #{path}"}
  end

  # Opens a buffer for a file that was just written to disk.
  # Best-effort: if the supervisor isn't running, the file still exists on disk.
  @spec open_buffer_for_written_file(String.t()) :: :ok
  defp open_buffer_for_written_file(path) do
    Buffer.ensure_for_path(path)
    :ok
  catch
    :exit, _ -> :ok
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
