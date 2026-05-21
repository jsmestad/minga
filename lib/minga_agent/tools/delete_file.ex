defmodule MingaAgent.Tools.DeleteFile do
  @moduledoc """
  Deletes a file from the project filesystem.

  ProjectView-aware routing happens in `MingaAgent.ToolRouter`; this module is the direct filesystem fallback when no routed workspace view is active.
  """

  alias Minga.Buffer
  alias Minga.Events

  @doc "Deletes the file at `path`."
  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path) when is_binary(path) do
    resolved = Path.expand(path)

    case open_buffer?(resolved) do
      {:ok, true} ->
        {:error,
         "cannot delete open buffer for #{resolved}; close the buffer or save/discard it first"}

      {:ok, false} ->
        case File.rm(resolved) do
          :ok ->
            broadcast_file_written(resolved)
            {:ok, "deleted #{resolved}"}

          {:error, :enoent} ->
            {:error, "file not found: #{resolved}"}

          {:error, :eisdir} ->
            {:error, "#{resolved} is a directory, not a file"}

          {:error, reason} ->
            {:error, "failed to delete #{resolved}: #{reason}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec open_buffer?(String.t()) :: {:ok, boolean()} | {:error, String.t()}
  defp open_buffer?(path) do
    case Buffer.pid_for_path(path) do
      {:ok, _pid} -> {:ok, true}
      :not_found -> {:ok, false}
    end
  catch
    :exit, _ ->
      {:error, "unable to verify buffer state for #{path}; close the buffer or retry the delete"}
  end

  @spec broadcast_file_written(String.t()) :: :ok
  defp broadcast_file_written(path) do
    Events.broadcast(:file_written, %Events.FileWrittenEvent{path: path, change_type: :deleted})
  end
end
