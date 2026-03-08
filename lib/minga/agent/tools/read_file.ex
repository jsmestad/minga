defmodule Minga.Agent.Tools.ReadFile do
  @moduledoc """
  Reads the contents of a file and returns it as a string.

  Handles missing files, permission errors, and binary files gracefully.
  Large files are truncated with a notice to prevent context window bloat.
  """

  @max_bytes 256_000

  @doc """
  Reads the file at `path` and returns its content.

  Files larger than #{div(@max_bytes, 1000)}KB are truncated. Binary (non-UTF-8)
  files are rejected with an error message.
  """
  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        cond do
          not String.valid?(content) ->
            {:error, "#{path} is a binary file, not a text file"}

          byte_size(content) > @max_bytes ->
            truncated = binary_part(content, 0, @max_bytes)
            {:ok, truncated <> "\n\n[truncated at #{div(@max_bytes, 1000)}KB]"}

          true ->
            {:ok, content}
        end

      {:error, :enoent} ->
        {:error, "file not found: #{path}"}

      {:error, :eisdir} ->
        {:error, "#{path} is a directory, not a file. Use list_directory instead."}

      {:error, reason} ->
        {:error, "failed to read #{path}: #{reason}"}
    end
  end
end
