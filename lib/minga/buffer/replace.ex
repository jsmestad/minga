defmodule Minga.Buffer.Replace do
  @moduledoc """
  Pure unique text replacement operations for buffer documents.

  This module owns the domain semantics for agent-style find-and-replace edits: the old text must exist exactly once, optional line boundaries are enforced against that unique match, and batch replacements apply sequentially while preserving per-edit results. `Buffer.Process` and `Buffer.Fork` wrap these pure operations with their own process, undo, version, and merge concerns.
  """

  alias Minga.Buffer.Document

  @typedoc "An edit boundary as `{start_line, end_line}` (both inclusive, 0-indexed), or nil for unbounded."
  @type boundary :: {non_neg_integer(), non_neg_integer()} | nil

  @typedoc "A find-and-replace edit pair for batch operations."
  @type edit :: {old_text :: String.t(), new_text :: String.t()}

  @typedoc "Result of a single replacement."
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @typedoc "Result of applying a batch of replacement edits."
  @type batch_result :: {Document.t(), [result()], any_applied? :: boolean()}

  @doc "Replaces `old_text` with `new_text` when the old text has exactly one match in the document."
  @spec unique(Document.t(), String.t(), String.t(), boundary()) ::
          {:ok, Document.t(), String.t()} | {:error, String.t()}
  def unique(%Document{} = doc, old_text, new_text, boundary \\ nil)
      when is_binary(old_text) and is_binary(new_text) do
    content = Document.content(doc)

    with {:ok, match} <- unique_match(content, old_text),
         :ok <- check_boundary(content, match, boundary) do
      {:ok, replace_match(content, match, new_text), "applied"}
    end
  end

  @doc "Applies unique replacements sequentially and returns the final document plus per-edit results."
  @spec batch(Document.t(), [edit()], boundary()) :: batch_result()
  def batch(%Document{} = doc, edits, boundary \\ nil) when is_list(edits) do
    {final_doc, results_reversed} =
      Enum.reduce(edits, {doc, []}, fn {old_text, new_text}, {current_doc, acc} ->
        case unique(current_doc, old_text, new_text, boundary) do
          {:ok, new_doc, msg} -> {new_doc, [{:ok, msg} | acc]}
          {:error, _} = err -> {current_doc, [err | acc]}
        end
      end)

    results = Enum.reverse(results_reversed)
    {final_doc, results, Enum.any?(results, &match?({:ok, _}, &1))}
  end

  @spec unique_match(String.t(), String.t()) ::
          {:ok, {non_neg_integer(), pos_integer()}} | {:error, String.t()}
  defp unique_match(_content, ""), do: {:error, "old_text is empty"}

  defp unique_match(content, old_text) do
    case :binary.matches(content, old_text) do
      [] -> {:error, "old_text not found"}
      [match] -> {:ok, match}
      matches -> {:error, "old_text found #{length(matches)} times (ambiguous)"}
    end
  end

  @spec check_boundary(String.t(), {non_neg_integer(), pos_integer()}, boundary()) ::
          :ok | {:error, String.t()}
  defp check_boundary(_content, _match, nil), do: :ok

  defp check_boundary(content, {offset, len}, {boundary_start, boundary_end}) do
    match_start_line = content |> binary_part(0, offset) |> count_newlines()

    match_end_line =
      content |> binary_part(offset, len) |> count_newlines() |> Kernel.+(match_start_line)

    if match_start_line >= boundary_start and match_end_line <= boundary_end do
      :ok
    else
      {:error,
       "edit outside boundary: match spans lines #{match_start_line}-#{match_end_line}, " <>
         "allowed range is #{boundary_start}-#{boundary_end}"}
    end
  end

  @spec count_newlines(binary()) :: non_neg_integer()
  defp count_newlines(binary) do
    binary
    |> :binary.matches("\n")
    |> length()
  end

  @spec replace_match(String.t(), {non_neg_integer(), pos_integer()}, String.t()) :: Document.t()
  defp replace_match(content, {offset, len}, new_text) do
    before_match = binary_part(content, 0, offset)
    after_match = binary_part(content, offset + len, byte_size(content) - offset - len)
    Document.new(before_match <> new_text <> after_match)
  end
end
