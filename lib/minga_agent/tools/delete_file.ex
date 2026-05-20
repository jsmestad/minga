defmodule MingaAgent.Tools.DeleteFile do
  @moduledoc """
  Deletes a file from the project filesystem.

  ProjectView-aware routing happens in `MingaAgent.ToolRouter`; this module is the direct filesystem fallback when no routed workspace view is active.
  """

  @doc "Deletes the file at `path`."
  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> {:ok, "deleted #{path}"}
      {:error, :enoent} -> {:error, "file not found: #{path}"}
      {:error, :eisdir} -> {:error, "#{path} is a directory, not a file"}
      {:error, reason} -> {:error, "failed to delete #{path}: #{reason}"}
    end
  end
end
