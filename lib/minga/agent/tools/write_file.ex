defmodule Minga.Agent.Tools.WriteFile do
  @moduledoc """
  Writes content to a file, creating parent directories as needed.
  """

  @doc """
  Writes `content` to the file at `path`.

  Creates any missing parent directories. Overwrites the file if it already
  exists. Returns `{:ok, message}` on success or `{:error, reason}` on failure.
  """
  @spec execute(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, content) when is_binary(path) and is_binary(content) do
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
