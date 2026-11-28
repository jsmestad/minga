defmodule Minga.Buffer.ReviewPositionTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.ReviewPosition
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.UndoPatch

  test "removing and restoring a blank row joins and splits heads while shifting distant ranks" do
    {history, document, _version} =
      fixture =
      history_for("ab\n\ncd\n\n\njk\nTAIL")
      |> edit({:minga, "near", "first"}, 0, 2, "AB")
      |> edit({:minga, "near", "second"}, 4, 2, "CD")
      |> edit({:minga, "far", "replace"}, 9, 2, "JK")
      |> edit({:minga, "far", "delete"}, 12, 4, "")

    index = ReviewPosition.build(history, document)
    original_heads = [0..1, 4..5, 9..10, 12..12]
    assert_ranks(index, document, original_heads)

    {history, document, _version} = joined = edit(fixture, :user, 3, 1, "")
    delta = EditDelta.deletion(3, 4, {1, 0}, {2, 0})
    index = ReviewPosition.revise(index, history, document, [], [delta])
    assert_ranks(index, document, [0..4, 8..9, 11..11])

    {history, document, _version} = edit(joined, :user, 3, 0, "\n")
    delta = EditDelta.insertion(3, {1, 0}, "\n", {2, 0})
    index = ReviewPosition.revise(index, history, document, [], [delta])
    assert_ranks(index, document, original_heads)
  end

  test "a coincident gap and text count once and cover up to the text's exclusive endpoint" do
    {history, document, _version} =
      history_for("ab\nxcde\n")
      |> edit({:minga, "text", "first"}, 0, 2, "AB")
      |> edit({:minga, "text", "second"}, 4, 3, "CDE")
      |> edit({:minga, "gap", "delete"}, 3, 1, "")

    assert_ranks(ReviewPosition.build(history, document), document, [0..1, 3..5])
  end

  test "an interior gap outranks the enclosing text only at the anchor" do
    {history, document, _version} =
      history_for("prefix\nabcde\ntrailing")
      |> edit({:minga, "task", "replace"}, 7, 5, "ABCDE")
      |> edit({:minga, "task", "delete"}, 9, 1, "")

    assert_ranks(ReviewPosition.build(history, document), document, [7..10, 9..9])
  end

  defp history_for(text) do
    document = Document.new(text)
    {UndoHistory.new(document), document, 0}
  end

  defp edit({history, document, version}, source, start, bytes, inserted) do
    removed = binary_part(Document.content(document), start, bytes)
    patch = UndoPatch.replacement(start, removed, inserted, Document.cursor(document))

    history =
      history
      |> UndoHistory.before_change(document)
      |> UndoHistory.record_edit(version, patch, source, version)
      |> UndoHistory.before_change(nil)

    {:ok, document} = Document.splice_byte_range(document, start, bytes, inserted, {0, 0})
    {history, document, version + 1}
  end

  defp assert_ranks(index, document, heads) do
    ranked = heads |> Enum.with_index(1) |> Enum.reverse()
    total = length(heads)

    for point <- 0..(Document.content_byte_size(document) + 1) do
      expected = Enum.find_value(ranked, fn {range, rank} -> if point in range, do: {rank, total} end)
      assert ReviewPosition.at(index, point) == expected, "unexpected review rank at byte #{point}"
    end
  end
end
