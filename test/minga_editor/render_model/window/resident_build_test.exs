defmodule MingaEditor.RenderModel.Window.ResidentBuildTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowSplice
  alias MingaEditor.RenderModel.Window.ResidentBuild
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.UI.FontRegistry

  test "hydration rejects ranged and incomplete sources before composition" do
    for source <- [{:range, 0, ["visible"]}, {:range, 120, ["visible"]}, {:complete, ["visible"]}] do
      inputs = %{
        source: source,
        plan: {:hydrate, :composition_context},
        line_count: 300,
        compose_fp: 1,
        highlight_fp: nil,
        reset?: false,
        hydration_reason: nil,
        keyframe?: false,
        retained_rows: %{},
        edit_deltas: [],
        font_registry: FontRegistry.new(),
        build_all: fn _ -> flunk("must reject incomplete source before composition") end,
        build_dirty: fn _, _ -> flunk("hydration must not enter the splice path") end
      }

      assert_raise ArgumentError,
                   "resident hydration requires a complete source from line zero",
                   fn ->
                     ResidentBuild.run(nil, inputs)
                   end
    end
  end

  test "splice plans reject source that does not cover the changed lines" do
    for plan <- [{:splice, 50, 1, 3}, {:splices, [49, 51]}] do
      assert_raise ArgumentError, "resident splice source does not cover inserted rows", fn ->
        ResidentBuild.run(nil, %{
          source: {:range, 50, ["only one line"]},
          plan: plan,
          keyframe?: false
        })
      end
    end
  end

  test "two local wrap edits use immutable-base visual ranks and preserve suffix hits" do
    suffix = group(2, 3, ["😀", "h"])
    original = [group(0, 1, ["a"]), group(1, 2, ["bc", "de"]), suffix]
    first = group(0, 1, ["a", "b", "c"])
    second = group(1, 2, ["de"])
    {base, _, _} = run_groups(nil, {:hydrate, :initial}, 3, original)
    {updated, result, _} = run_groups(base, {:splices, [0, 1]}, 3, [first, second])

    assert %{base_row_count: 5, result_row_count: 6, splices: [one, two]} = result.row_delta
    assert {one.start_index, one.delete_count, RowSplice.insert_count(one)} == {0, 1, 3}
    assert {two.start_index, two.delete_count, RowSplice.insert_count(two)} == {1, 2, 1}
    assert result.source_splices == [{0, 1, 1}, {1, 1, 1}]
    assert result.work.rows_visited == 7
    assert ResidentStore.entry_at(base.store, 4) == ResidentStore.entry_at(updated.store, 5)

    {fresh, _, _} = run_groups(nil, {:hydrate, :initial}, 3, [first, second, suffix])
    assert ResidentStore.payloads(updated.store) == ResidentStore.payloads(fresh.store)
    assert ResidentStore.digest(updated.store) == ResidentStore.digest(fresh.store)

    assert {:ok, continuation} = ResidentStore.payload_at(updated.store, 5)
    assert VisualRow.source_position(continuation, 0) == {:ok, {2, 4}}
  end

  test "newline splice retains suffix row identity and reprojects source lines lazily" do
    {base, _, _} =
      run_groups(nil, {:hydrate, :initial}, 2, [
        group(0, 1, ["ab", "cd"]),
        group(1, 2, ["é", "f"])
      ])

    {grown, result, _} =
      run_groups(base, {:splice, 0, 1, 2}, 3, [group(0, 1, ["ab"]), group(1, 3, ["cd"])])

    assert %{base_row_count: 4, result_row_count: 4, splices: [splice]} = result.row_delta
    assert {splice.start_index, splice.delete_count, RowSplice.insert_count(splice)} == {0, 2, 2}
    assert ResidentStore.entry_at(base.store, 3) == ResidentStore.entry_at(grown.store, 3)
    assert {:ok, continuation} = ResidentStore.payload_at(grown.store, 3)
    assert VisualRow.source_position(continuation, 0) == {:ok, {2, 2}}

    {restored, _, _} = run_groups(grown, {:splice, 0, 2, 1}, 2, [group(0, 1, ["ab", "cd"])])
    assert ResidentStore.payloads(restored.store) == ResidentStore.payloads(base.store)
  end

  defp run_groups(previous, plan, count, groups) do
    payloads = List.flatten(groups)
    source = {:complete, List.duplicate("", count)}

    ResidentBuild.run(previous, %{
      source: source,
      plan: plan,
      line_count: count,
      compose_fp: 1,
      highlight_fp: nil,
      reset?: false,
      hydration_reason: nil,
      retained_rows: %{},
      edit_deltas: [],
      keyframe?: false,
      font_registry: FontRegistry.new(),
      build_all: fn registry -> {payloads, registry} end,
      build_dirty: fn dirty, registry ->
        by_line = Map.new(groups, fn [entry | _] = rows -> {entry.buf_line, rows} end)
        assert dirty == MapSet.new(Map.keys(by_line))
        {by_line, registry}
      end
    })
  end

  defp group(line, source_id, texts) do
    whole = Enum.join(texts)
    map = SourceOffsetMap.new(whole, whole, Decorations.new(), line)

    {rows, _} =
      texts
      |> Enum.with_index()
      |> Enum.map_reduce({0, 0}, fn {text, offset}, {byte, utf16} ->
        kind = if offset == 0, do: :normal, else: :wrap_continuation
        last_byte = byte + byte_size(text)
        last_utf16 = utf16 + div(byte_size(:unicode.characters_to_binary(text, :utf8, :utf16)), 2)

        row = %Row{
          row_id: Row.stable_id(kind, source_id, offset),
          row_type: kind,
          buf_line: line,
          visual_index: offset,
          text: text,
          spans: [],
          content_hash: Row.compute_hash(text, [])
        }

        entry =
          VisualRow.new(
            row,
            SourceOffsetMap.slice(map, byte, last_byte, utf16, last_utf16),
            byte,
            last_byte,
            0
          )

        {entry, {last_byte, last_utf16}}
      end)

    rows
  end
end
