defmodule Minga.Test.SequentialRangeReplace do
  @moduledoc """
  The batch range-replacement algorithm as it was before `Minga.Buffer.RangeBatch`.

  It applies each edit with `Minga.Buffer.Operation.replace_range/4`, from the highest start position to the lowest, against the document the previous edit produced. Tests and `bench/batch_replacements.exs` use it as the behavioral control for `Minga.Buffer.Operation.replace_ranges_with_patches/2`.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Operation
  alias Minga.Buffer.UndoPatch

  @doc "Applies `edits` one at a time and returns undo patches in newest-first recording order."
  @spec replace_ranges_with_patches(Document.t(), [Operation.range_edit()]) ::
          {Document.t(), [UndoPatch.t()]}
  def replace_ranges_with_patches(%Document{} = doc, edits) when is_list(edits) do
    edits
    |> Enum.sort(fn {from_a, _, _}, {from_b, _, _} -> from_a >= from_b end)
    |> Enum.reduce({doc, []}, fn {from_pos, to_pos, replacement}, {acc_doc, patches} ->
      {:edited, new_doc, delta} = Operation.replace_range(acc_doc, from_pos, to_pos, replacement)
      patch = UndoPatch.from_delta(delta, acc_doc)
      {new_doc, [patch | patches]}
    end)
  end
end
