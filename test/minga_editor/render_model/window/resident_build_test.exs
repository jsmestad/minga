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
    for source <- [
          {:ranges, [{0, ["visible"]}]},
          {:ranges, [{120, ["visible"]}]},
          {:complete, ["visible"]}
        ] do
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
    for plan <- [
          {:splices, [{50, 1, 3}]},
          {:splices, [{49, 1, 1}, {51, 1, 1}]},
          {:splices, [{50, 1, 1}, {60, 1, 1}]}
        ] do
      assert_raise ArgumentError, "resident splice source does not cover inserted rows", fn ->
        ResidentBuild.run(nil, %{
          source: {:ranges, [{50, ["only one line"]}]},
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

    {updated, result, _} =
      run_groups(base, {:splices, [{0, 1, 1}, {1, 1, 1}]}, 3, [first, second])

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
      run_groups(base, {:splices, [{0, 1, 2}]}, 3, [group(0, 1, ["ab"]), group(1, 3, ["cd"])])

    assert %{base_row_count: 4, result_row_count: 4, splices: [splice]} = result.row_delta
    assert {splice.start_index, splice.delete_count, RowSplice.insert_count(splice)} == {0, 2, 2}
    assert ResidentStore.entry_at(base.store, 3) == ResidentStore.entry_at(grown.store, 3)
    assert {:ok, continuation} = ResidentStore.payload_at(grown.store, 3)
    assert VisualRow.source_position(continuation, 0) == {:ok, {2, 2}}

    {restored, _, _} = run_groups(grown, {:splices, [{0, 2, 1}]}, 2, [group(0, 1, ["ab", "cd"])])
    assert ResidentStore.payloads(restored.store) == ResidentStore.payloads(base.store)
  end

  describe "two structural edits far apart in one frame" do
    setup do
      original = for line <- 0..5, do: group(line, line + 1, ["line #{line}"])
      {base, _, _} = run_groups(nil, {:hydrate, :initial}, 6, original)
      %{base: base}
    end

    test "each edit is its own splice, and the rows between them are kept, not rebuilt", %{
      base: base
    } do
      # Line 1 becomes three lines and line 5 becomes two. The second splice addresses the store before
      # the first one grew it, and reads its new lines two lines further down.
      inserted = [
        group(1, 11, ["one a"]),
        group(2, 12, ["one b"]),
        group(3, 13, ["one c"]),
        group(7, 14, ["five a"]),
        group(8, 15, ["five b"])
      ]

      {updated, result, _} =
        run_groups(base, {:splices, [{1, 1, 3}, {5, 1, 2}]}, 9, inserted)

      assert %{base_row_count: 6, result_row_count: 9, splices: [one, two]} = result.row_delta
      assert {one.start_index, one.delete_count, RowSplice.insert_count(one)} == {1, 1, 3}
      assert {two.start_index, two.delete_count, RowSplice.insert_count(two)} == {5, 1, 2}
      assert result.source_splices == [{1, 1, 3}, {5, 1, 2}]
      assert result.rasterized == 5

      for {before, later} <- [{0, 0}, {2, 4}, {3, 5}, {4, 6}] do
        assert ResidentStore.entry_at(base.store, before) ==
                 ResidentStore.entry_at(updated.store, later)
      end

      assert ResidentStore.line_count(updated.store) == 9
      assert ResidentStore.visual_rank(updated.store, 7) == 7
    end

    test "a large deletion and an insertion elsewhere stay two splices", %{base: base} do
      {updated, result, _} =
        run_groups(base, {:splices, [{0, 3, 1}, {5, 1, 2}]}, 5, [
          group(0, 21, ["joined"]),
          group(3, 22, ["five a"]),
          group(4, 23, ["five b"])
        ])

      assert %{base_row_count: 6, result_row_count: 5, splices: [one, two]} = result.row_delta
      assert {one.start_index, one.delete_count, RowSplice.insert_count(one)} == {0, 3, 1}
      assert {two.start_index, two.delete_count, RowSplice.insert_count(two)} == {5, 1, 2}
      assert ResidentStore.entry_at(base.store, 3) == ResidentStore.entry_at(updated.store, 1)
      assert ResidentStore.entry_at(base.store, 4) == ResidentStore.entry_at(updated.store, 2)
    end

    test "the plan keeps distant edits apart instead of spanning them", %{base: base} do
      deltas = [line_delta(1, 1, 3), line_delta(7, 7, 8)]

      assert ResidentBuild.plan(base, plan_inputs(deltas, 9)) ==
               {:splices, [{1, 1, 3}, {5, 1, 2}]}
    end

    test "an in-place edit beside a structural edit elsewhere is still two splices", %{base: base} do
      deltas = [line_delta(0, 0, 0), line_delta(4, 4, 6)]

      assert ResidentBuild.plan(base, plan_inputs(deltas, 8)) ==
               {:splices, [{0, 1, 1}, {4, 1, 3}]}
    end

    test "edits whose line counts do not reach the new document hydrate", %{base: base} do
      assert {:hydrate, _reason} =
               ResidentBuild.plan(base, plan_inputs([line_delta(1, 1, 3)], 6))
    end
  end

  defp line_delta(start, old_end, new_end) do
    Minga.Buffer.EditDelta.replacement(0, 0, {start, 0}, {old_end, 0}, "", {new_end, 0})
  end

  defp plan_inputs(deltas, line_count) do
    %{
      compose_fp: 1,
      highlight_fp: nil,
      reset?: false,
      hydration_reason: nil,
      edit_deltas: deltas,
      line_count: line_count
    }
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
