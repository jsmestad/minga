defmodule Minga.Frontend.Adapter.GUI.ResidentGutterTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Gutter
  alias Minga.RenderModel.Window.Gutter.ResidentRows
  alias Minga.RenderModel.Window.GutterEntry
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowDelta

  test "resident overrides are retained only after acknowledgement and replaced on identity changes" do
    model =
      window(300, 7, [%GutterEntry{buf_line: 120, display_type: :normal, sign_type: :diag_error}])

    {first, caches} = GUI.encode_windows([model], Caches.new())
    assert resident_header(first) == {7, 300, 0}
    assert override_count(first) == 1

    {unacknowledged, caches} = GUI.encode_windows([model], caches)
    assert resident_header(unacknowledged) == {7, 300, 0}
    caches = Caches.acknowledge_pending_window_deltas(caches)

    moved = %{model | gutter: %{model.gutter | cursor_line: 50}}
    {retained, caches} = GUI.encode_windows([moved], caches)
    assert resident_header(retained) == {7, 300, 1}
    assert override_sections(retained) == []

    cleared = window(300, 7, [])
    {replaced, caches} = GUI.encode_windows([cleared], caches)
    assert resident_header(replaced) == {7, 300, 0}
    assert override_sections(replaced) == [<<0::16>>]

    caches = Caches.acknowledge_pending_window_deltas(caches)
    {switched, caches} = GUI.encode_windows([window(300, 8, [])], caches)
    assert resident_header(switched) == {8, 300, 0}

    caches = Caches.acknowledge_pending_window_deltas(caches)
    {resized, _caches} = GUI.encode_windows([window(301, 8, [])], caches)
    assert resident_header(resized) == {8, 301, 0}

    {recovered, _caches} = GUI.encode_windows([cleared], Caches.new())
    assert resident_header(recovered) == {7, 300, 0}
    assert override_sections(recovered) == [<<0::16>>]
  end

  test "large exception snapshots use bounded repeated sections without dropping signs" do
    entries =
      for line <- 0..9_999,
          do: %GutterEntry{buf_line: line, display_type: :normal, sign_type: :git_added}

    commands = WindowEncoder.encode_frame_metadata(window(10_000, 1, entries))
    sections = override_sections(commands)
    assert [_, _ | _] = sections
    assert override_count(commands) == 10_000
    assert Enum.all?(sections, &(byte_size(&1) <= 65_535))

    lines =
      for <<count::16, encoded::binary>> <- sections,
          <<line::32, _::binary-size(6) <- encoded>> do
        assert count > 0
        line
      end

    assert lines == Enum.to_list(0..9_999)
  end

  test "acknowledged resident deltas keep reference candidates separate from complete snapshots" do
    model = window(300, 7, [])
    {_commands, caches} = GUI.encode_windows([model], Caches.new())
    caches = Caches.acknowledge_pending_window_deltas(caches)
    edited = %{Enum.at(model.rows, 220) | text: "changed", content_hash: 2}
    next_rows = List.replace_at(model.rows, 220, edited)
    delta = RowDelta.from_snapshots(model.rows, next_rows)
    partial = %{model | rows: [edited], row_delta: delta, content_digest: 2}
    {commands, caches} = GUI.encode_windows([partial], caches)
    assert Enum.any?(commands, &match?(<<0xA2, _::binary>>, &1))
    caches = Caches.acknowledge_pending_window_deltas(caches)
    refute Map.has_key?(caches.last_window_rows, 1)
    refute Map.has_key?(caches.last_window_row_keys, 1)
    assert caches.last_resident_row_keys[1] == [{edited.row_id, edited.content_hash}]

    rebuilt = %{model | rows: next_rows, content_digest: 2}
    {commands, _caches} = GUI.encode_windows([rebuilt], caches)
    assert Enum.any?(commands, &match?(<<0x80, _::binary>>, &1))
    refute Enum.any?(commands, &match?(<<0xA2, _::binary>>, &1))
  end

  defp window(count, epoch, overrides) do
    rows =
      for line <- 0..(count - 1),
          do: %Row{
            row_id: line,
            row_type: :normal,
            buf_line: line,
            text: "line",
            spans: [],
            content_hash: 1
          }

    %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 80, 20},
      rows: rows,
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      content_epoch: epoch,
      full_refresh: false,
      row_store_mode: {:resident, count},
      gutter: %Gutter{
        window_id: 1,
        content_row: 0,
        content_col: 0,
        content_height: 20,
        is_active: true,
        content_width: 80,
        cursor_line: 0,
        line_number_style: :absolute,
        line_number_width: 4,
        sign_col_width: 3,
        entries: %ResidentRows{content_epoch: epoch, line_count: count, overrides: overrides}
      }
    }
  end

  defp resident_header(commands) do
    [{4, <<epoch::32, count::32, retain::8>>}] =
      Enum.filter(gutter_sections(commands), &(elem(&1, 0) == 4))

    {epoch, count, retain}
  end

  defp override_sections(commands),
    do: for({5, payload} <- gutter_sections(commands), do: payload)

  defp override_count(commands),
    do: Enum.sum(for <<count::16, _::binary>> <- override_sections(commands), do: count)

  defp gutter_sections(commands) do
    [<<0x7B, count::8, payload::binary>>] =
      Enum.filter(commands, &match?(<<0x7B, _::binary>>, &1))

    sections = for <<id::8, size::16, data::binary-size(size) <- payload>>, do: {id, data}
    assert length(sections) == count
    sections
  end
end
