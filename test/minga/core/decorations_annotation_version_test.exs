defmodule Minga.Core.DecorationsAnnotationVersionTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Core.Face

  test "annotation revision changes only for annotation content mutations" do
    decorations = Decorations.new()

    {_highlight, with_highlight} =
      Decorations.add_highlight(decorations, {0, 0}, {0, 1}, style: Face.new(bg: 0x112233))

    assert with_highlight.annotation_version == 0

    {annotation, with_annotation} = Decorations.add_annotation(with_highlight, 3, "note")
    assert with_annotation.annotation_version == 1

    shifted = Decorations.adjust_for_edit(with_annotation, {0, 0}, {0, 0}, {1, 0})
    assert shifted.annotation_version == 1
    assert [%{line: 4}] = shifted.annotations

    removed = Decorations.remove_annotation(shifted, annotation)
    assert removed.annotation_version == 2
  end

  test "dense annotation range queries use the line cache and return only the requested rows" do
    decorations =
      Enum.reduce(0..9_999, Decorations.new(), fn line, acc ->
        {_id, next} = Decorations.add_annotation(acc, line, "note #{line}")
        next
      end)
      |> Decorations.build_ann_line_cache()

    assert map_size(decorations.ann_line_cache) == 10_000

    assert [%{line: 5_000, text: "note 5000"}] =
             Decorations.annotations_for_range(decorations, 5_000, 5_001)
  end
end
