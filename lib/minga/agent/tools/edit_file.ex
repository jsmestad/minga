defmodule Minga.Agent.Tools.EditFile do
  @moduledoc """
  Replaces exact text in a file.

  The old text must match exactly, including whitespace and indentation. This is
  the same semantics as pi's edit tool: find-and-replace on the raw file content.
  """

  @doc """
  Replaces `old_text` with `new_text` in the file at `path`.

  Returns `{:ok, message}` on success. Fails if the file doesn't exist, if
  `old_text` is not found, or if `old_text` appears more than once (ambiguous edit).
  """
  @spec execute(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, old_text, new_text)
      when is_binary(path) and is_binary(old_text) and is_binary(new_text) do
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
    # Count occurrences to detect ambiguity
    parts = String.split(content, old_text)
    occurrence_count = length(parts) - 1

    case occurrence_count do
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
