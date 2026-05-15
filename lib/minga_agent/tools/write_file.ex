defmodule MingaAgent.Tools.WriteFile do
  @moduledoc """
  Writes content to a file, creating parent directories as needed.

  Routes through `Buffer.replace_content/2` when a buffer is open
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
    expanded = Path.expand(path)

    case Buffer.pid_for_path(expanded) do
      {:ok, pid} -> execute_via_buffer(pid, expanded, content)
      :not_found -> create_and_open(expanded, content)
    end
  end

  @spec create_and_open(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp create_and_open(path, content) do
    existed = File.exists?(path)

    case execute_via_filesystem(path, content) do
      {:ok, msg} ->
        open_buffer_for_written_file(path)
        change_type = if existed, do: :changed, else: :created
        broadcast_file_written(path, change_type)
        {:ok, msg}

      error ->
        error
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

  @spec broadcast_file_written(String.t(), :created | :changed) :: :ok
  defp broadcast_file_written(path, change_type) do
    Minga.Events.broadcast(:file_written, %Minga.Events.FileWrittenEvent{
      path: path,
      change_type: change_type
    })
  end
end
