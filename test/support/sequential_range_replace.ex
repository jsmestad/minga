defmodule Minga.Test.SequentialRangeReplace do
  @moduledoc """
  The batch range-replacement contract as a plain sequential algorithm, without `Minga.Buffer.RangeBatch`.

  It applies each edit with `Minga.Buffer.Operation.replace_range/4`, from the highest start position to the lowest, against the document the previous edit produced. It rejects the batch when the input document, or any document an edit produces, is not valid UTF-8, checking each whole document rather than the bytes around the edit. Tests and `bench/batch_replacements.exs` use it as the behavioral control for `Minga.Buffer.Operation.replace_ranges_with_patches/2`.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Operation
  alias Minga.Buffer.UndoPatch
  alias Minga.Core.Unicode

  @doc "Applies `edits` one at a time and returns undo patches in newest-first recording order."
  @spec replace_ranges_with_patches(Document.t(), [Operation.range_edit()]) ::
          {:ok, Document.t(), [UndoPatch.t()]} | {:error, Operation.batch_error()}
  def replace_ranges_with_patches(%Document{} = doc, []), do: {:ok, doc, []}

  def replace_ranges_with_patches(%Document{} = doc, edits) when is_list(edits) do
    [{_edit, first_index} | _rest] =
      ordered =
      edits
      |> Enum.with_index()
      |> Enum.sort(fn {{from_a, _, _}, _}, {{from_b, _, _}, _} -> from_a >= from_b end)

    if Unicode.valid_utf8?(Document.content(doc)) do
      Enum.reduce_while(ordered, {:ok, doc, []}, &apply_edit/2)
    else
      {:error, {:edit_failed, first_index, :invalid_utf8}}
    end
  end

  # `replace_range/4` rejects an edit that would leave invalid UTF-8 itself; the whole-document
  # check stays as the independent oracle for that rejection.
  defp apply_edit({{from_pos, to_pos, replacement}, index}, {:ok, acc_doc, patches}) do
    case Operation.replace_range(acc_doc, from_pos, to_pos, replacement) do
      {:edited, new_doc, delta} ->
        if Unicode.valid_utf8?(Document.content(new_doc)) do
          {:cont, {:ok, new_doc, [UndoPatch.from_delta(delta, acc_doc) | patches]}}
        else
          {:halt, {:error, {:edit_failed, index, :invalid_utf8}}}
        end

      {:error, reason} ->
        {:halt, {:error, {:edit_failed, index, reason}}}
    end
  end
end
