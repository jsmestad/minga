defmodule Minga.Agent.Tools.ReadFile do
  @moduledoc """
  Reads the contents of a file and returns it as a string.

  Handles missing files, permission errors, and binary files gracefully.
  Large files are truncated with a notice to prevent context window bloat.

  Supports optional `offset` (1-indexed line number) and `limit` (max lines)
  parameters for partial file reads. When provided, only the requested slice
  is returned with a position header so the model knows where it is in the file.
  """

  @max_bytes 256_000

  @typedoc "Options for partial file reads."
  @type read_opts :: [offset: pos_integer() | nil, limit: pos_integer() | nil]

  @doc """
  Reads the file at `path` and returns its content.

  Files larger than #{div(@max_bytes, 1000)}KB are truncated. Binary (non-UTF-8)
  files are rejected with an error message.

  ## Options

    * `:offset` - 1-indexed line number to start reading from (default: nil, read from start)
    * `:limit` - maximum number of lines to return (default: nil, read to end)

  When offset/limit are provided, the result includes a header like
  `[lines 500-550 of 10000]` so the model knows its position in the file.
  """
  @spec execute(String.t(), read_opts()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, opts \\ []) when is_binary(path) do
    offset = Keyword.get(opts, :offset)
    limit = Keyword.get(opts, :limit)

    case File.read(path) do
      {:ok, content} ->
        validate_and_read(path, content, offset, limit)

      {:error, :enoent} ->
        {:error, "file not found: #{path}"}

      {:error, :eisdir} ->
        {:error, "#{path} is a directory, not a file. Use list_directory instead."}

      {:error, reason} ->
        {:error, "failed to read #{path}: #{reason}"}
    end
  end

  @spec validate_and_read(String.t(), String.t(), pos_integer() | nil, pos_integer() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  defp validate_and_read(path, content, nil, nil) do
    # No offset/limit: original behavior
    case String.valid?(content) do
      false ->
        {:error, "#{path} is a binary file, not a text file"}

      true ->
        if byte_size(content) > @max_bytes do
          truncated = binary_part(content, 0, @max_bytes)
          {:ok, truncated <> "\n\n[truncated at #{div(@max_bytes, 1000)}KB]"}
        else
          {:ok, content}
        end
    end
  end

  defp validate_and_read(path, content, offset, limit) do
    case String.valid?(content) do
      false ->
        {:error, "#{path} is a binary file, not a text file"}

      true ->
        all_lines = String.split(content, "\n")
        total_lines = length(all_lines)
        read_partial(all_lines, total_lines, offset, limit)
    end
  end

  @spec read_partial([String.t()], non_neg_integer(), pos_integer() | nil, pos_integer() | nil) ::
          {:ok, String.t()}
  defp read_partial(all_lines, total_lines, offset, limit) do
    # offset is 1-indexed; convert to 0-indexed for Enum.slice
    start_idx = max((offset || 1) - 1, 0)

    if start_idx >= total_lines do
      {:ok, "[offset #{start_idx + 1} is beyond end of file (#{total_lines} lines)]"}
    else
      read_partial_slice(all_lines, total_lines, start_idx, limit)
    end
  end

  @spec read_partial_slice(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer() | nil
        ) ::
          {:ok, String.t()}
  defp read_partial_slice(all_lines, total_lines, start_idx, limit) do
    sliced =
      case limit do
        nil -> Enum.slice(all_lines, start_idx..-1//1)
        n when is_integer(n) and n > 0 -> Enum.slice(all_lines, start_idx, n)
        _ -> Enum.slice(all_lines, start_idx..-1//1)
      end

    end_line = start_idx + length(sliced)
    start_line = start_idx + 1

    header = "[lines #{start_line}-#{end_line} of #{total_lines}]\n"
    result = header <> Enum.join(sliced, "\n")

    # Still respect the byte limit for partial reads
    if byte_size(result) > @max_bytes do
      truncated = binary_part(result, 0, @max_bytes)
      {:ok, truncated <> "\n\n[truncated at #{div(@max_bytes, 1000)}KB]"}
    else
      {:ok, result}
    end
  end
end
