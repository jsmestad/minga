defmodule Minga.Conformance.ProductionRenderCorpusTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowDelta
  alias Minga.Test.HeadlessPort

  @corpus Path.expand("corpus/store/production_render_boundaries.json", __DIR__)

  test "BEAM production transaction gate observes the shared 65,536-row corpus" do
    %{"steps" => [%{"fixture" => fixture, "operations" => operations}]} =
      @corpus |> File.read!() |> JSON.decode!()

    assert fixture["row_count"] == 65_536
    assert fixture["wide_text_bytes"] > 65_535
    assert fixture["comparison_row_count"] == 5_000

    wide = :binary.copy("w", fixture["wide_text_bytes"])

    rows =
      for index <- 0..(fixture["row_count"] - 1) do
        %Row{
          row_id: index + 1,
          row_type: :normal,
          buf_line: index,
          text:
            if(index == 0, do: wide, else: fixture["row_text_prefix"] <> Integer.to_string(index)),
          spans: [],
          content_hash: index + 1
        }
      end

    port = start_supervised!({HeadlessPort, width: 80, height: 24})
    keyframe = window(rows, fixture["content_epoch"])

    {keyframe_commands, caches, _metrics} =
      GUI.encode_windows_with_metrics([keyframe], Caches.new())

    submit(port, 1, 0, fixture["recovery_generation"], keyframe_commands)
    assert_observed(port, operations, "keyframe", :accepted)
    state = HeadlessPort.production_state(port)
    assert state.windows[1].row_count == fixture["row_count"]
    assert byte_size(hd(state.windows[1].rows).text) == fixture["wide_text_bytes"]

    edit_index = fixture["ordinary_edit_index"]

    edited_rows =
      List.update_at(rows, edit_index, &%{&1 | text: "edited", content_hash: &1.content_hash + 1})

    {edit_commands, caches, _metrics} =
      GUI.encode_windows_with_metrics(
        [delta_window(edited_rows, rows, fixture["content_epoch"])],
        caches
      )

    assert splice_work(edit_commands) == {1, 1}
    submit(port, 2, 1, fixture["recovery_generation"], edit_commands)
    assert_observed(port, operations, "ordinary_edit", :accepted)
    caches = Caches.acknowledge_window_delta(caches, 1)

    assert HeadlessPort.production_state(port).windows[1].rows
           |> Enum.at(edit_index)
           |> Map.fetch!(:text) == "edited"

    structural_index = fixture["structural_edit_index"]

    inserted = %Row{
      row_id: 0xFFFF_FFFF_FFFF_FFFE,
      row_type: :normal,
      buf_line: structural_index,
      text: "inserted",
      spans: [],
      content_hash: 0xA11CE
    }

    structural_rows = List.insert_at(edited_rows, structural_index, inserted)

    {structural_commands, caches, _metrics} =
      GUI.encode_windows_with_metrics(
        [delta_window(structural_rows, edited_rows, fixture["content_epoch"])],
        caches
      )

    assert splice_work(structural_commands) == {1, 1}

    submit(port, 3, 2, fixture["recovery_generation"], structural_commands)
    assert_observed(port, operations, "structural_edit_near_start", :accepted)
    caches = Caches.acknowledge_window_delta(caches, 1)

    # Moving an unchanged row makes the real encoder emit retained-row refs.
    retained_index = fixture["ordinary_edit_index"] + 1
    retained_rows = swap(structural_rows, retained_index, retained_index + 1)

    {retained_commands, _caches, _metrics} =
      GUI.encode_windows_with_metrics(
        [delta_window(retained_rows, structural_rows, fixture["content_epoch"])],
        caches
      )

    assert count_refs(retained_commands) > 0
    submit(port, 4, 3, fixture["recovery_generation"], retained_commands)
    assert_observed(port, operations, "retained_reference", :accepted)

    committed = HeadlessPort.production_state(port)
    ref_miss_commands = patch_first_ref_id(retained_commands, 0xFFFF_FFFF_FFFF_FFFF)
    submit(port, 5, 4, fixture["recovery_generation"], ref_miss_commands)
    assert_observed(port, operations, "reference_miss", :recovery_required)
    assert HeadlessPort.production_state(port).windows == committed.windows

    stale_epoch_commands = patch_content_epoch(retained_commands, fixture["stale_content_epoch"])
    submit(port, 6, 4, fixture["recovery_generation"], stale_epoch_commands)
    assert_observed(port, operations, "stale_content_epoch", :stale_discarded)
    assert HeadlessPort.production_state(port).windows == committed.windows

    submit(port, 7, 4, fixture["stale_recovery_generation"], retained_commands)
    assert_observed(port, operations, "stale_recovery_generation", :stale_discarded)
    assert HeadlessPort.production_state(port).windows == committed.windows

    {reset_commands, _caches, _metrics} =
      GUI.encode_windows_with_metrics([window(rows, fixture["content_epoch"] + 1)], Caches.new())

    submit(port, 8, 0, fixture["recovery_generation"], reset_commands)
    assert_observed(port, operations, "reset_full_recovery", :accepted)
    assert HeadlessPort.production_state(port).windows[1].row_count == fixture["row_count"]
  end

  defp submit(port, seq, base, generation, commands) do
    :accepted = HeadlessPort.send_transaction(port, seq, base, generation, commands)
    _ = HeadlessPort.production_state(port)
  end

  defp assert_observed(port, operations, name, observed) do
    assert HeadlessPort.production_state(port).outcome == observed
    assert expected(operations, name, "expect_status") == Atom.to_string(observed)
  end

  defp window(rows, epoch) do
    %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 80, 24},
      rows: rows,
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      content_epoch: epoch,
      full_refresh: true
    }
  end

  defp delta_window(rows, previous_rows, epoch) do
    %{
      window(rows, epoch)
      | full_refresh: false,
        row_delta: RowDelta.from_snapshots(previous_rows, rows)
    }
  end

  defp swap(rows, left, right) do
    a = Enum.at(rows, left)
    b = Enum.at(rows, right)
    rows |> List.replace_at(left, b) |> List.replace_at(right, a)
  end

  defp expected(operations, name, field),
    do: operations |> Enum.find(&(&1["name"] == name)) |> Map.fetch!(field)

  # Observe the encoder's actual row-splice section rather than copying fixture counts.
  defp splice_work(commands) do
    Enum.reduce(commands, {0, 0}, fn command, {splices, inserted} ->
      case find_section(command, 0x0B) do
        <<_base::32, _result::32, count::32, rest::binary>> ->
          {splices + count, inserted + splice_insert_count(rest, count, 0)}

        nil ->
          {splices, inserted}
      end
    end)
  end

  defp splice_insert_count(_rest, 0, count), do: count

  defp splice_insert_count(
         <<_start::32, _delete::32, insert::32, rows::binary>>,
         remaining,
         count
       ) do
    {_, tail} = take_rows(rows, insert)
    splice_insert_count(tail, remaining - 1, count + insert)
  end

  defp count_refs(commands) do
    Enum.reduce(commands, 0, fn command, total ->
      case find_section(command, 0x0B) do
        <<_base::32, _result::32, count::32, rest::binary>> ->
          total + count_splice_refs(rest, count, 0)

        nil ->
          total
      end
    end)
  end

  defp count_splice_refs(_rest, 0, count), do: count

  defp count_splice_refs(<<_start::32, _delete::32, insert::32, rows::binary>>, remaining, count) do
    {refs, tail} = take_rows(rows, insert)
    count_splice_refs(tail, remaining - 1, count + refs)
  end

  defp take_rows(rest, 0), do: {0, rest}

  defp take_rows(<<0, _id::64, _hash::32, rest::binary>>, count) do
    {refs, tail} = take_rows(rest, count - 1)
    {refs + 1, tail}
  end

  defp take_rows(
         <<1, _type, _id::64, _line::32, _hash::32, text_len::32, _text::binary-size(text_len),
           span_count::16, rest::binary>>,
         count
       ) do
    span_bytes = span_count * 12
    <<_spans::binary-size(^span_bytes), tail::binary>> = rest
    take_rows(tail, count - 1)
  end

  defp find_section(<<_opcode, count, sections::binary>>, id),
    do: find_section_payload(sections, count, id)

  defp find_section_payload(_rest, 0, _id), do: nil

  defp find_section_payload(
         <<id, len::32, payload::binary-size(len), _rest::binary>>,
         _count,
         id
       ),
       do: payload

  defp find_section_payload(
         <<_id, len::32, _payload::binary-size(len), rest::binary>>,
         count,
         id
       ),
       do: find_section_payload(rest, count - 1, id)

  defp patch_content_epoch(commands, epoch),
    do: Enum.map(commands, &patch_header_epoch(&1, epoch))

  defp patch_header_epoch(<<opcode, count, sections::binary>>, epoch),
    do: <<opcode, count, patch_sections_epoch(sections, count, epoch)::binary>>

  defp patch_sections_epoch(rest, 0, _epoch), do: rest

  defp patch_sections_epoch(
         <<1, len::32, window_id::16, _old::32, tail::binary-size(len - 6), rest::binary>>,
         count,
         epoch
       ),
       do:
         <<1, len::32, window_id::16, epoch::32, tail::binary,
           patch_sections_epoch(rest, count - 1, epoch)::binary>>

  defp patch_sections_epoch(
         <<id, len::32, payload::binary-size(len), rest::binary>>,
         count,
         epoch
       ),
       do: <<id, len::32, payload::binary, patch_sections_epoch(rest, count - 1, epoch)::binary>>

  defp patch_first_ref_id(commands, id) do
    {patched, _} =
      Enum.map_reduce(commands, false, fn command, done ->
        if(done, do: {command, true}, else: patch_command_ref(command, id))
      end)

    patched
  end

  defp patch_command_ref(<<opcode, count, sections::binary>>, id) do
    {sections, done} = patch_sections_ref(sections, count, id)
    {<<opcode, count, sections::binary>>, done}
  end

  defp patch_sections_ref(rest, 0, _id), do: {rest, false}

  defp patch_sections_ref(<<0x0B, len::32, payload::binary-size(len), rest::binary>>, _count, id) do
    {payload, done} = patch_payload_ref(payload, id)
    {<<0x0B, len::32, payload::binary, rest::binary>>, done}
  end

  defp patch_sections_ref(
         <<section, len::32, payload::binary-size(len), rest::binary>>,
         count,
         id
       ) do
    {tail, done} = patch_sections_ref(rest, count - 1, id)
    {<<section, len::32, payload::binary, tail::binary>>, done}
  end

  defp patch_payload_ref(<<base::32, result::32, count::32, rest::binary>>, id),
    do: {<<base::32, result::32, count::32, patch_splice_ref(rest, id)::binary>>, true}

  defp patch_splice_ref(
         <<start::32, delete::32, insert::32, 0, _old::64, hash::32, rest::binary>>,
         id
       ),
       do: <<start::32, delete::32, insert::32, 0, id::64, hash::32, rest::binary>>
end
