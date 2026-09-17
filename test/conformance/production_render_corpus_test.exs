defmodule Minga.Conformance.ProductionRenderCorpusTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.Cursor
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowDelta
  alias Minga.Test.HeadlessPort
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.ComposedFrame
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.Renderer.Submission

  import MingaEditor.RenderPipeline.TestHelpers, only: [gui_state: 1]

  @corpus Path.expand("corpus/store/production_render_boundaries.json", __DIR__)
  @render_timeout 15_000

  test "matching renderer acknowledgements keep a 100-row window incremental" do
    rows = rows(100, "row-")
    first_edit = replace_row(rows, 50, "first edit")
    second_edit = replace_row(first_edit, 50, "second edit")

    frames = %{
      1 => composed_frame(window(rows, 1)),
      2 => composed_frame(delta_window(first_edit, rows, 1)),
      3 => composed_frame(delta_window(second_edit, first_edit, 1))
    }

    port = start_supervised!({HeadlessPort, width: 80, height: 24})
    {renderer, frontend, intent} = start_acknowledged_renderer(frames)

    {full, _state} = render_and_ack(renderer, frontend, port, intent, 1)
    {first_delta, _state} = render_and_ack(renderer, frontend, port, intent, 2)
    {second_delta, state} = render_and_ack(renderer, frontend, port, intent, 3)

    assert frame_window_opcodes(full) == [Opcodes.gui_window_content()]
    assert frame_window_opcodes(first_delta) == [Opcodes.gui_window_rows_delta()]
    assert frame_window_opcodes(second_delta) == [Opcodes.gui_window_rows_delta()]
    assert state.windows[1].row_count == 100
    assert state.windows[1].rows |> Enum.at(50) |> Map.fetch!(:text) == "second edit"
  end

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

    keyframe = window(rows, fixture["content_epoch"])
    edit_index = fixture["ordinary_edit_index"]

    edited_rows =
      List.update_at(rows, edit_index, &%{&1 | text: "edited", content_hash: &1.content_hash + 1})

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

    # Moving an unchanged row makes the real encoder emit retained-row refs.
    retained_index = fixture["ordinary_edit_index"] + 1
    retained_rows = swap(structural_rows, retained_index, retained_index + 1)

    frames = %{
      1 => composed_frame(keyframe),
      2 => composed_frame(delta_window(edited_rows, rows, fixture["content_epoch"])),
      3 => composed_frame(delta_window(structural_rows, edited_rows, fixture["content_epoch"])),
      4 => composed_frame(delta_window(retained_rows, structural_rows, fixture["content_epoch"]))
    }

    port = start_supervised!({HeadlessPort, width: 80, height: 24})
    {renderer, frontend, intent} = start_acknowledged_renderer(frames)

    {keyframe_commands, _state} = render_and_ack(renderer, frontend, port, intent, 1)

    assert count_opcode(keyframe_commands, Opcodes.gui_window_content()) == 1
    assert count_opcode(keyframe_commands, Opcodes.gui_window_rows_delta()) == 0

    assert_observed(port, operations, "keyframe", :accepted)
    state = HeadlessPort.production_state(port)
    recovery_generation = state.recovery_generation
    assert state.windows[1].row_count == fixture["row_count"]
    assert byte_size(hd(state.windows[1].rows).text) == fixture["wide_text_bytes"]

    {edit_commands, _state} = render_and_ack(renderer, frontend, port, intent, 2)

    assert count_opcode(edit_commands, Opcodes.gui_window_content()) == 0
    assert count_opcode(edit_commands, Opcodes.gui_window_rows_delta()) == 1
    assert IO.iodata_length(edit_commands) < IO.iodata_length(keyframe_commands)
    assert splice_work(edit_commands) == {1, 1}
    assert_observed(port, operations, "ordinary_edit", :accepted)

    assert HeadlessPort.production_state(port).windows[1].rows
           |> Enum.at(edit_index)
           |> Map.fetch!(:text) == "edited"

    {structural_commands, _state} = render_and_ack(renderer, frontend, port, intent, 3)

    assert count_opcode(structural_commands, Opcodes.gui_window_content()) == 0
    assert count_opcode(structural_commands, Opcodes.gui_window_rows_delta()) == 1
    assert IO.iodata_length(structural_commands) < IO.iodata_length(keyframe_commands)
    assert splice_work(structural_commands) == {1, 1}

    assert_observed(port, operations, "structural_edit_near_start", :accepted)

    {retained_frame_commands, _state} = render_and_ack(renderer, frontend, port, intent, 4)
    retained_commands = frame_payload(retained_frame_commands)

    assert count_refs(retained_commands) > 0
    assert_observed(port, operations, "retained_reference", :accepted)

    committed = HeadlessPort.production_state(port)
    ref_miss_commands = patch_first_ref_id(retained_commands, 0xFFFF_FFFF_FFFF_FFFF)
    submit(port, 5, 4, recovery_generation, ref_miss_commands)
    assert_observed(port, operations, "reference_miss", :recovery_required)
    assert HeadlessPort.production_state(port).windows == committed.windows

    stale_epoch_commands = patch_content_epoch(retained_commands, fixture["stale_content_epoch"])
    submit(port, 6, 4, recovery_generation, stale_epoch_commands)
    assert_observed(port, operations, "stale_content_epoch", :stale_discarded)
    assert HeadlessPort.production_state(port).windows == committed.windows

    submit(port, 7, 4, recovery_generation - 1, retained_commands)
    assert_observed(port, operations, "stale_recovery_generation", :stale_discarded)
    assert HeadlessPort.production_state(port).windows == committed.windows

    {reset_commands, _caches, _metrics} =
      GUI.encode_windows_with_metrics([window(rows, fixture["content_epoch"] + 1)], Caches.new())

    submit(port, 8, 0, recovery_generation, reset_commands)
    assert_observed(port, operations, "reset_full_recovery", :accepted)
    assert HeadlessPort.production_state(port).windows[1].row_count == fixture["row_count"]
  end

  defp submit(port, seq, base, generation, commands) do
    :accepted = HeadlessPort.send_transaction(port, seq, base, generation, commands)
    _ = HeadlessPort.production_state(port)
  end

  defp start_acknowledged_renderer(frames) do
    frontend =
      start_supervised!(Supervisor.child_spec({RecordingFrontend, owner: self()}, id: make_ref()))

    state =
      [port_manager: frontend, backend: :native_gui]
      |> gui_state()
      |> RenderPipeline.compute_layout()

    intent = Intent.from_editor_state(state)

    renderer =
      start_supervised!(
        Supervisor.child_spec(
          {RendererServer,
           name: nil,
           editor_pid: self(),
           pipeline: gui_emit_pipeline(frames),
           require_ack?: true,
           generation_reserver: generation_reserver(),
           ack_timeout_ms: @render_timeout},
          id: make_ref()
        )
      )

    {renderer, frontend, intent}
  end

  defp generation_reserver do
    counter = :atomics.new(1, [])
    fn -> :atomics.add_get(counter, 1, 1) end
  end

  defp gui_emit_pipeline(frames) do
    fn %Input{} = input ->
      frame = Map.fetch!(frames, input.frame_seq)
      ctx = Context.from_input(input)

      {caches, font_registry, message_store} = Emit.emit(frame, ctx, nil, input.caches)
      Input.accept_emit_results(input, caches, font_registry, message_store)
    end
  end

  defp render_and_ack(renderer, frontend, port, intent, frame_seq) do
    RendererServer.cast_snapshot(
      renderer,
      Submission.full(intent),
      frame_seq
    )

    assert_receive {:frontend_commands, ^frontend,
                    [
                      <<begin_frame, ^frame_seq::32, base_frame_seq::32, generation::32>> | _
                    ] = commands},
                   @render_timeout

    assert begin_frame == Opcodes.begin_frame()
    assert Enum.at(commands, -1) == <<Opcodes.commit_frame(), frame_seq::32, 0::32>>
    assert {:awaiting_ack, lease, nil} = :sys.get_state(renderer).frame_credit
    assert lease.attempt.seq == frame_seq
    assert lease.generation == generation
    assert base_frame_seq == max(frame_seq - 1, 0)

    :accepted = HeadlessPort.send_commands(port, commands)
    applied = HeadlessPort.production_state(port)
    assert applied.outcome == :accepted

    RendererServer.frame_status(renderer, {:frame_applied, generation, frame_seq})
    assert_receive {:render_done, %RenderReceipt{frame_seq: ^frame_seq}}, @render_timeout

    {commands, applied}
  end

  defp assert_observed(port, operations, name, observed) do
    assert HeadlessPort.production_state(port).outcome == observed
    assert expected(operations, name, "expect_status") == Atom.to_string(observed)
  end

  defp count_opcode(commands, opcode),
    do: Enum.count(commands, &match?(<<^opcode, _::binary>>, &1))

  defp frame_window_opcodes(commands) do
    for <<opcode, _::binary>> <- commands, opcode in window_opcodes(), do: opcode
  end

  defp frame_payload([<<begin_frame, _::binary>> | rest]) do
    assert begin_frame == Opcodes.begin_frame()

    rest
    |> Enum.drop(-1)
    |> Enum.filter(&(opcode(&1) in window_opcodes()))
  end

  defp composed_frame(window), do: ComposedFrame.new([window], Cursor.new(0, 0, :block))

  defp rows(count, prefix) do
    for index <- 0..(count - 1) do
      %Row{
        row_id: index + 1,
        row_type: :normal,
        buf_line: index,
        text: prefix <> Integer.to_string(index),
        spans: [],
        content_hash: index + 1
      }
    end
  end

  defp replace_row(rows, index, text) do
    List.update_at(rows, index, &%{&1 | text: text, content_hash: &1.content_hash + 1})
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

  defp find_section(<<opcode, count, sections::binary>>, id) do
    if opcode in [Opcodes.gui_window_viewport_delta(), Opcodes.gui_window_rows_delta()],
      do: find_section_payload(sections, count, id),
      else: nil
  end

  defp opcode(<<opcode, _::binary>>), do: opcode

  defp window_opcodes do
    [
      Opcodes.gui_window_content(),
      Opcodes.gui_window_overlay_delta(),
      Opcodes.gui_window_viewport_delta(),
      Opcodes.gui_window_rows_delta()
    ]
  end

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
