defmodule Minga.Buffer.Replace do
  @moduledoc """
  Pure text replacement operations for buffer documents.

  This module owns the domain semantics for agent-style find-and-replace edits: the expected text must identify exactly one replacement target, optional line boundaries are enforced against that target, and batch replacements apply sequentially while preserving per-edit results. `Buffer.Process` and `Buffer.Fork` wrap these pure operations with their own process, undo, version, and merge concerns.
  """

  alias Minga.Buffer.{Document, EditDelta, Position, UndoPatch}

  @typedoc "An edit boundary as `{start_line, end_line}` (both inclusive, 0-indexed), or nil for unbounded."
  @type boundary :: {non_neg_integer(), non_neg_integer()} | nil

  @typedoc "A find-and-replace edit pair for batch operations."
  @type edit :: {old_text :: String.t(), new_text :: String.t()}

  @typedoc "Result of a single replacement."
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @typedoc "Result of applying a batch of replacement edits."
  @type batch_result :: {Document.t(), [result()], any_applied? :: boolean()}

  @typedoc "Successful replacement with the edit delta that describes it."
  @type delta_result :: {:ok, Document.t(), EditDelta.t(), String.t()} | {:error, String.t()}

  @doc "Applies a replacement when `old_text` identifies exactly one target in the document."
  @spec apply(Document.t(), String.t(), String.t(), boundary()) ::
          {:ok, Document.t(), String.t()} | {:error, String.t()}
  def apply(%Document{} = doc, old_text, new_text, boundary \\ nil)
      when is_binary(old_text) and is_binary(new_text) do
    case apply_with_delta(doc, old_text, new_text, boundary) do
      {:ok, new_doc, _delta, msg} -> {:ok, new_doc, msg}
      {:error, _} = err -> err
    end
  end

  @doc "Applies a replacement and returns the edit delta that describes the changed range."
  @spec apply_with_delta(Document.t(), String.t(), String.t(), boundary()) :: delta_result()
  def apply_with_delta(%Document{} = doc, old_text, new_text, boundary \\ nil)
      when is_binary(old_text) and is_binary(new_text) do
    content = Document.content(doc)

    with {:ok, match} <- find_replacement_target(content, old_text),
         :ok <- check_boundary(content, match, boundary) do
      new_doc = replace_match(content, match, new_text)
      {:ok, new_doc, replacement_delta(doc, new_doc, match, new_text), "applied"}
    end
  end

  @doc "Applies replacements sequentially and returns the final document plus per-edit results."
  @spec apply_batch(Document.t(), [edit()], boundary()) :: batch_result()
  def apply_batch(%Document{} = doc, edits, boundary \\ nil) when is_list(edits) do
    {final_doc, results, _patches} = apply_batch_with_deltas(doc, edits, boundary)
    {final_doc, results, Enum.any?(results, &match?({:ok, _}, &1))}
  end

  @doc "Applies replacements sequentially and returns the final document, per-edit results, and undo patches in newest-first order."
  @spec apply_batch_with_deltas(Document.t(), [edit()], boundary()) ::
          {Document.t(), [result()], [UndoPatch.t()]}
  def apply_batch_with_deltas(%Document{} = doc, edits, boundary \\ nil) when is_list(edits) do
    {final_doc, results_reversed, patches} =
      Enum.reduce(edits, {doc, [], []}, fn {old_text, new_text},
                                           {current_doc, results, patches} ->
        case apply_with_delta(current_doc, old_text, new_text, boundary) do
          {:ok, new_doc, delta, msg} ->
            patch = UndoPatch.from_delta(delta, current_doc)
            {new_doc, [{:ok, msg} | results], [patch | patches]}

          {:error, _} = err ->
            {current_doc, [err | results], patches}
        end
      end)

    {final_doc, Enum.reverse(results_reversed), patches}
  end

  @spec find_replacement_target(String.t(), String.t()) ::
          {:ok, {non_neg_integer(), pos_integer()}} | {:error, String.t()}
  defp find_replacement_target(_content, ""), do: {:error, "old_text is empty"}

  defp find_replacement_target(content, old_text) do
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

  @spec replacement_delta(
          Document.t(),
          Document.t(),
          {non_neg_integer(), pos_integer()},
          String.t()
        ) ::
          EditDelta.t()
  defp replacement_delta(%Document{} = doc, %Document{} = new_doc, {offset, len}, new_text) do
    EditDelta.replacement(
      offset,
      offset + len,
      Position.from_point(doc, offset),
      Position.from_point(doc, offset + len),
      new_text,
      Position.from_point(new_doc, offset + byte_size(new_text))
    )
  end

  @spec replace_match(String.t(), {non_neg_integer(), pos_integer()}, String.t()) :: Document.t()
  defp replace_match(content, {offset, len}, new_text) do
    before_match = binary_part(content, 0, offset)
    after_match = binary_part(content, offset + len, byte_size(content) - offset - len)
    Document.new(before_match <> new_text <> after_match)
  end
end
