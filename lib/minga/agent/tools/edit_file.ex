defmodule Minga.Agent.Tools.EditFile do
  @moduledoc """
  Replaces exact text in a file.

  Routes through `Buffer.Server.find_and_replace/3` when a buffer is open
  for the file (atomic, undoable, no disk I/O). Falls back to filesystem
  I/O when no buffer exists.

  The old text must match exactly, including whitespace and indentation.
  """

  alias Minga.Buffer.Server, as: BufferServer

  @doc """
  Replaces `old_text` with `new_text` in the file at `path`.

  Returns `{:ok, message}` on success. Fails if the file doesn't exist, if
  `old_text` is not found, or if `old_text` appears more than once (ambiguous edit).
  """
  @spec execute(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, old_text, new_text)
      when is_binary(path) and is_binary(old_text) and is_binary(new_text) do
    case BufferServer.pid_for_path(path) do
      {:ok, pid} -> execute_via_buffer(pid, path, old_text, new_text)
      :not_found -> execute_via_filesystem(path, old_text, new_text)
    end
  end

  @spec execute_via_buffer(pid(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_via_buffer(pid, path, old_text, new_text) do
    case BufferServer.find_and_replace(pid, old_text, new_text) do
      {:ok, _} -> {:ok, "edited #{path}"}
      {:error, reason} -> {:error, "#{reason} in #{path}. Read the file first to get exact text."}
    end
  catch
    :exit, _ -> {:error, "buffer process died for #{path}"}
  end

  @spec execute_via_filesystem(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_via_filesystem(path, old_text, new_text) do
    case File.read(path) do
      {:ok, content} ->
        apply_edit(path, content, old_text, new_text)

      {:error, :enoent} ->
        {:error, "file not found: #{path}"}

      {:error, reason} ->
        {:error, "failed to read #{path}: #{reason}"}
    end
  end

  @spec apply_edit(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_edit(path, content, old_text, new_text) do
    case length(:binary.matches(content, old_text)) do
      0 ->
        {:error, "old_text not found in #{path}. Read the file first to get exact text."}

      1 ->
        new_content = String.replace(content, old_text, new_text, global: false)

        case File.write(path, new_content) do
          :ok ->
            {:ok, "edited #{path}"}

          {:error, reason} ->
            {:error, "failed to write #{path}: #{reason}"}
        end

      n ->
        {:error, "old_text found #{n} times in #{path}. Make the match more specific."}
    end
  end
end
