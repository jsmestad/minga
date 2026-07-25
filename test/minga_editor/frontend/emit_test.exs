defmodule MingaEditor.Frontend.EmitTest do
  @moduledoc """
  Tests for the Emit stage dispatcher and shared helpers.

  GUI chrome cache tests are in `emit/gui_chrome_cache_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion
  alias Minga.RenderModel.Cursor
  alias MingaEditor.RenderPipeline.ComposedFrame
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.Frontend.Emit.Context
  alias Minga.Core.Face
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.Window, as: RenderWindow
  alias Minga.RenderModel.Window.IndentGuides
  alias Minga.RenderModel.Window.Row, as: RenderRow
  alias Minga.RenderModel.Window.Span, as: RenderSpan
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.FontRegistry

  import MingaEditor.RenderPipeline.TestHelpers

  @op_begin_frame Opcodes.begin_frame()

  setup do
    frontend =
      start_supervised!(
        {RecordingFrontend, owner: self()},
        id: {:emit_recording_frontend, System.unique_integer([:positive])}
      )

    Process.put(:emit_test_frontend, frontend)
    :ok
  end

  describe "context projection" do
    test "active completion survives the typed render-input projection" do
      completion = Completion.new([], {0, 0})

      state =
        ModalWorkflow.open(
          emit_state(),
          {:completion, CompletionPayload.new(1, completion: completion)}
        )

      assert Context.from_editor_state(state).completion == completion

      windows = Windows.set_active(state.workspace.windows, 999)
      workspace = SessionState.set_windows(state.workspace, windows)
      state = %{state | workspace: workspace}

      assert Context.from_editor_state(state).completion == completion
    end
  end

  describe "emit/2 dispatching" do
    test "TUI path emits a semantic frame, not a leading cell-grid clear" do
      frame = ComposedFrame.new([], Cursor.new(0, 0, :block))

      state = emit_state()
      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      commands = assert_receive_frame_commands()

      # The TUI renders via the semantic GUI protocol, now bracketed as a frame
      # transaction (#2219): every frame opens with begin_frame (0x10) and closes
      # with commit_frame (0x11). The frame no longer starts with a cell-grid clear.
      refute Enum.any?(commands, &match?(<<0x12, _::binary>>, &1))
      assert [<<first_opcode, frame_seq::32, base_frame_seq::32, _generation::32>> | _] = commands
      assert first_opcode == Opcodes.begin_frame()
      # First frame is a keyframe (no committed base), so base_frame_seq is 0.
      assert base_frame_seq == 0
      # commit_frame closes the frame, carrying frame_seq + echoed input_seq (ticket
      # #2215). With no key seq in scope the echo is 0; frame_seq matches begin_frame.
      assert Enum.at(commands, -1) == <<Opcodes.commit_frame(), frame_seq::32, 0::32>>
    end

    test "GUI path produces commands (no clear expected for GUI with to_commands)" do
      frame = ComposedFrame.new([], Cursor.new(0, 0, :block))

      state = gui_state(port_manager: Process.get(:emit_test_frontend))
      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      commands = assert_receive_frame_commands()
      assert is_list(commands)
      assert Enum.all?(commands, &is_binary/1)
    end

    test "semantic TUI path emits semantic window commands instead of cell-grid clear" do
      frame = build_frame_with_window(emit_state(), viewport_top: 0)

      row = %RenderRow{
        row_id: RenderRow.stable_id(:normal, 0),
        row_type: :normal,
        buf_line: 0,
        text: "semantic",
        spans: [%RenderSpan{start_col: 0, end_col: 8, fg: 0xBBC2CF, bg: 0x282C34, attrs: 0}]
      }

      window_model = %RenderWindow{
        window_id: 1,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        rows: [row],
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block
      }

      frame = %{frame | windows: [window_model]}

      state = emit_state(capabilities: %Capabilities{frontend_type: :tui, semantic_ui: true})

      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      commands = assert_receive_frame_commands()
      refute match?([<<0x12>> | _], commands)

      assert Enum.any?(commands, fn
               <<0x80, _::binary>> -> true
               _ -> false
             end)
    end
  end

  describe "frame transactions (#2219)" do
    test "every frame is bracketed with begin_frame/commit_frame and a monotonic frame_seq" do
      frame = window_frame_with_content()
      state = semantic_state()

      caches = %Caches{}
      {commands1, _caches} = emit_and_capture(frame, state, caches, frame_seq: 100)
      {commands2, _caches} = emit_and_capture(frame, state, caches, frame_seq: 200)

      assert [<<op_begin, fs1::32, _base::32, _generation::32>> | _] = commands1
      assert op_begin == Opcodes.begin_frame()
      assert Enum.at(commands1, -1) == <<Opcodes.commit_frame(), fs1::32, 0::32>>

      assert [<<_, fs2::32, _base::32, _generation::32>> | _] = commands2
      # frame_seq advances per emit even though the snapshot is identical.
      assert fs2 > fs1
    end

    test "the first frame is a keyframe (base 0) carrying full window content" do
      frame = window_frame_with_content()
      state = semantic_state()

      {commands, _caches} = emit_and_capture(frame, state, %Caches{}, frame_seq: 7)

      assert [<<_, 7::32, base_frame_seq::32, _generation::32>> | _] = commands
      assert base_frame_seq == 0

      assert Enum.any?(commands, &match?(<<0x80, _::binary>>, &1)),
             "keyframe carries full window content"
    end

    test "a successful Port write does not become a delta base without acknowledgement" do
      frame = window_frame_with_content()
      state = semantic_state()

      {_commands, unacknowledged} = emit_and_capture(frame, state, %Caches{}, frame_seq: 11)
      {commands, _caches} = emit_and_capture(frame, state, unacknowledged, frame_seq: 22)

      assert [<<_, 22::32, 0::32, _generation::32>> | _] = commands
      assert Enum.any?(commands, &match?(<<0x80, _::binary>>, &1))
    end

    test "a renderer without a frontend treats synchronous emission as the commit boundary" do
      frame = window_frame_with_content()

      ctx =
        Context.from_editor_state(semantic_state()) |> put_frame_seq(11) |> put_port_manager(nil)

      {caches, _font_registry, _message_store} = Emit.emit(frame, ctx, nil, %Caches{})
      assert caches.last_acknowledged_frame_seq == 11
      assert caches.last_frame_keyframe?

      ctx = put_frame_seq(ctx, 22)
      {caches, _font_registry, _message_store} = Emit.emit(frame, ctx, nil, caches)
      assert caches.last_acknowledged_frame_seq == 22
      refute caches.last_frame_keyframe?
    end

    test "a later frame names the previous frame_seq as its delta base" do
      frame = window_frame_with_content()
      state = semantic_state()

      {_c1, caches} = emit_and_capture(frame, state, %Caches{}, frame_seq: 11)
      caches = acknowledge(caches, 11)
      {commands, _c2} = emit_and_capture(frame, state, caches, frame_seq: 22)

      assert [<<_, 22::32, base_frame_seq::32, _generation::32>> | _] = commands
      assert base_frame_seq == 11, "non-keyframe bases on the previously acknowledged frame_seq"
    end

    test "an invalid late window field writes nothing and the next valid frame recovers with a keyframe" do
      frame = window_frame_with_content()
      state = semantic_state()

      {_commands, caches} = emit_and_capture(frame, state, %Caches{}, frame_seq: 11)
      caches = acknowledge(caches, 11)
      invalid_frame = frame_with_invalid_indent_level(frame)
      ctx = %{Context.from_editor_state(state) | frame_seq: 22}

      {recovered_caches, _font_registry, _message_store} =
        Emit.emit(invalid_frame, ctx, nil, caches)

      refute_receive {:frontend_commands, _frontend, [<<@op_begin_frame, _::binary>> | _]}
      assert recovered_caches.adapter_gui_caches == Minga.Frontend.Adapter.GUI.Caches.new()
      assert recovered_caches.last_emitted_frame_seq == 0

      {commands, _caches} = emit_and_capture(frame, state, recovered_caches, frame_seq: 33)

      assert [<<_, 33::32, 0::32, _generation::32>> | _] = commands
      assert Enum.any?(commands, &match?(<<0x80, _::binary>>, &1))
    end

    test "request_keyframe forces the next frame back to base 0 with full window content" do
      frame = window_frame_with_content()
      state = semantic_state()

      # Establish a delta base: frame two bases on frame one and skips full content.
      {_c1, caches} = emit_and_capture(frame, state, %Caches{}, frame_seq: 11)
      caches = acknowledge(caches, 11)
      {delta_commands, caches} = emit_and_capture(frame, state, caches, frame_seq: 22)

      refute Enum.any?(delta_commands, &match?(<<0x80, _::binary>>, &1)),
             "unchanged second frame does not resend full window content"

      # A forced keyframe drops the deltas: base 0 and full content again.
      {key_commands, _caches} =
        emit_and_capture(frame, state, caches, frame_seq: 33, force_keyframe?: true)

      assert [<<_, 33::32, 0::32, _generation::32>> | _] = key_commands

      assert Enum.any?(key_commands, &match?(<<0x80, _::binary>>, &1)),
             "forced keyframe resends full window content"
    end

    # Regression (#2219): a keyframe re-establishes the frontend from scratch, so it
    # must drop the title/window-bg side-channel caches too, so a frontend that lost
    # its title or background mid-session gets them back. Here we pin that the keyframe
    # branch resets last_frame_keyframe? and re-derives the side channels from the
    # current render model rather than carrying a stale cached value forward. The
    # end-to-end re-send (the actual set_title/set_window_bg commands) is pinned in
    # emit/keyframe_side_channel_test.exs, which observes the named Frontend.Manager.
    test "a forced keyframe re-derives the title and window-bg side channels" do
      frame = window_frame_with_content()
      state = semantic_state()

      # Compute the values a normal frame would cache, so we can prove the keyframe
      # reset path lands on the freshly recomputed values, not the seeded ones.
      {_c0, fresh} = emit_and_capture(frame, state, %Caches{}, frame_seq: 5)

      # Seed caches with stale side-channel values plus a committed base.
      seeded = %Caches{
        last_title: "stale title",
        last_window_bg: 0x123456,
        last_emitted_frame_seq: 22,
        last_acknowledged_frame_seq: 22
      }

      {_key, key_caches} =
        emit_and_capture(frame, state, seeded, frame_seq: 33, force_keyframe?: true)

      assert key_caches.last_frame_keyframe?
      # The stale seed was dropped; the keyframe re-derived both side channels.
      assert key_caches.last_title == fresh.last_title
      assert key_caches.last_window_bg == fresh.last_window_bg
      refute key_caches.last_title == "stale title"
      refute key_caches.last_window_bg == 0x123456
    end
  end

  describe "font registry ownership" do
    # In the semantic architecture, font ids are allocated during the
    # render-pipeline content stage (the window builder's `font_id_for_face`,
    # which fires for styled virtual-text segments). Emit flushes the resulting
    # pending registrations as `register_font` (0x52) commands. The old splash
    # cell-grid allocation path no longer exists, so this drives a styled
    # virtual-text decoration through the full pipeline instead.
    test "styled virtual text allocates a font id and emits a register_font command" do
      face = %Face{name: "vt", fg: 0xFFFFFF, bg: 0x000000, font_family: "Fira Code"}

      state = emit_state(content: "hello\nworld")
      buffer = state.workspace.buffers.active

      BufferProcess.add_virtual_text(buffer, {0, 0},
        segments: [{"VT", face}],
        placement: :above,
        priority: 0
      )

      run_pipeline(state)
      commands = assert_receive_frame_commands()

      # register_font (0x52) with the first allocated id (1), then the family
      # length and bytes. The window builder allocated the id during the content
      # stage and emit flushed it.
      assert Enum.any?(commands, fn
               <<0x52, 1, _len::16, "Fira Code">> -> true
               _ -> false
             end)

      refute Process.get(:emit_font_registry)
    end

    test "flushes font registrations allocated before emit" do
      frame = ComposedFrame.new([], Cursor.new(0, 0, :block))

      {_id, registry, true} = FontRegistry.get_or_register(FontRegistry.new(), "Fira Code")
      ctx = %{Context.from_editor_state(emit_state()) | font_registry: registry}

      {_caches, font_registry, _message_store} = Emit.emit(frame, ctx, nil, %Caches{})
      commands = assert_receive_frame_commands()

      assert FontRegistry.pending_registrations(font_registry) == []

      assert Enum.any?(commands, fn
               <<0x52, 1, _::binary>> -> true
               _ -> false
             end)
    end
  end

  describe "send_title (shared)" do
    test "sends title command only when title changes" do
      frame = ComposedFrame.new([], Cursor.new(0, 0, :block))

      state = emit_state()
      ctx = Context.from_editor_state(state)
      caches0 = %Caches{}

      {caches1, _font_registry, _message_store} = Emit.emit(frame, ctx, nil, caches0)
      # Flush first commands + title
      _commands = assert_receive_frame_commands()

      assert is_binary(caches1.last_title)

      # Emit again with same ctx; title should not be re-sent (cache hit)
      {caches2, _font_registry, _message_store} = Emit.emit(frame, ctx, nil, caches1)
      _commands2 = assert_receive_frame_commands()

      assert caches2.last_title == caches1.last_title
    end
  end

  describe "send_window_bg (shared)" do
    test "sends background command only when theme changes" do
      frame = ComposedFrame.new([], Cursor.new(0, 0, :block))

      state = emit_state()
      ctx = Context.from_editor_state(state)
      caches0 = %Caches{}

      {caches1, _font_registry, _message_store} = Emit.emit(frame, ctx, nil, caches0)
      _ = assert_receive_frame_commands()

      assert caches1.last_window_bg == state.appearance.theme.editor.bg

      # Emit again, should not re-send
      {caches2, _font_registry, _message_store} = Emit.emit(frame, ctx, nil, caches1)
      _ = assert_receive_frame_commands()
      assert caches2.last_window_bg == caches1.last_window_bg
    end
  end

  # ── Frame-transaction test helpers ───────────────────────────────────────

  defp semantic_state do
    emit_state(capabilities: %Capabilities{frontend_type: :tui, semantic_ui: true})
  end

  defp window_frame_with_content do
    frame = build_frame_with_window(emit_state(), viewport_top: 0)

    row = %RenderRow{
      row_id: RenderRow.stable_id(:normal, 0),
      row_type: :normal,
      buf_line: 0,
      text: "semantic",
      spans: [%RenderSpan{start_col: 0, end_col: 8, fg: 0xBBC2CF, bg: 0x282C34, attrs: 0}]
    }

    window_model = %RenderWindow{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 80, 20},
      rows: [row],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block
    }

    %{frame | windows: [window_model]}
  end

  defp frame_with_invalid_indent_level(frame) do
    [window] = frame.windows

    indent_guides = %IndentGuides{
      window_id: window.window_id,
      tab_width: 2,
      active_guide_col: 2,
      guide_cols: [2],
      line_indent_levels: [0, 256]
    }

    %{frame | windows: [%{window | indent_guides: indent_guides}]}
  end

  # Drives Emit.emit/4 with an explicit frame_seq and optional keyframe forcing,
  # capturing the admitted frame batch from the recording frontend.
  defp acknowledge(caches, frame_seq) do
    Caches.acknowledge_frame(caches, frame_seq, caches.recovery_generation)
  end

  defp emit_and_capture(frame, state, caches, opts) do
    ctx =
      state
      |> Context.from_editor_state()
      |> put_frame_seq(Keyword.fetch!(opts, :frame_seq))
      |> put_force_keyframe(Keyword.get(opts, :force_keyframe?, false))
      |> Map.put(:acknowledgement_required?, true)

    {new_caches, _font_registry, _message_store} = Emit.emit(frame, ctx, nil, caches)
    commands = assert_receive_frame_commands()
    {commands, new_caches}
  end

  defp put_frame_seq(ctx, frame_seq), do: %{ctx | frame_seq: frame_seq}

  defp put_force_keyframe(ctx, force?) do
    frame = %{ctx.intent.frame | force_keyframe?: force?}
    %{ctx | intent: %{ctx.intent | frame: frame}}
  end

  defp put_port_manager(ctx, port_manager) do
    frame = %{ctx.intent.frame | port_manager: port_manager}
    %{ctx | intent: %{ctx.intent | frame: frame}, acknowledgement_required?: false}
  end

  defp assert_receive_frame_commands do
    assert_receive {:frontend_commands, _frontend,
                    [<<@op_begin_frame, _::binary>> | _] = commands}

    commands
  end

  defp emit_state(opts \\ []) do
    base_state(Keyword.put(opts, :port_manager, Process.get(:emit_test_frontend)))
  end
end
