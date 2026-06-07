defmodule MingaEditor.Frontend.EmitTest do
  @moduledoc """
  Tests for the Emit stage dispatcher and shared helpers.

  TUI-specific tests are in `emit/tui_test.exs`.
  GUI-specific tests are in `emit/gui_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, Frame}
  alias MingaEditor.Layout
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.Frontend.Emit.Context
  alias Minga.Core.Face
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.Window, as: RenderWindow
  alias Minga.RenderModel.Window.Row, as: RenderRow
  alias Minga.RenderModel.Window.Span, as: RenderSpan
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.UI.FontRegistry

  import MingaEditor.RenderPipeline.TestHelpers

  describe "emit/2 dispatching" do
    test "TUI path emits a semantic frame, not a leading cell-grid clear" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      assert_receive {:"$gen_cast", {:send_commands, commands}}

      # The TUI now renders via the semantic GUI protocol. The frame no longer
      # starts with a cell-grid clear (0x12); it opens with chrome commands and
      # closes with batch_end (0x13).
      refute match?([<<0x12>> | _], commands)
      assert [<<first_opcode, _::binary>> | _] = commands
      assert first_opcode >= 0x70
      assert List.last(commands) == <<Opcodes.batch_end()>>
    end

    test "GUI path produces commands (no clear expected for GUI with to_commands)" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = gui_state()
      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert is_list(commands)
      assert Enum.all?(commands, &is_binary/1)
    end

    test "semantic TUI path emits semantic window commands instead of cell-grid clear" do
      frame = build_frame_with_window(base_state(), viewport_top: 0)
      [window_frame] = frame.windows

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

      frame = %{frame | windows: [%{window_frame | window_model: window_model}]}

      state = %{
        base_state()
        | capabilities: %Capabilities{frontend_type: :tui, semantic_ui: true}
      }

      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      refute match?([<<0x12>> | _], commands)

      assert Enum.any?(commands, fn
               <<0x80, _::binary>> -> true
               _ -> false
             end)
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

      state = base_state(content: "hello\nworld")
      buffer = state.workspace.buffers.active

      BufferProcess.add_virtual_text(buffer, {0, 0},
        segments: [{"VT", face}],
        placement: :above,
        priority: 0
      )

      run_pipeline(state)
      assert_receive {:"$gen_cast", {:send_commands, commands}}

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
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      {_id, registry, true} = FontRegistry.get_or_register(FontRegistry.new(), "Fira Code")
      ctx = %{Context.from_editor_state(base_state()) | font_registry: registry}

      {_caches, font_registry} = Emit.emit(frame, ctx, nil, %Caches{})
      assert_receive {:"$gen_cast", {:send_commands, commands}}

      assert FontRegistry.pending_registrations(font_registry) == []

      assert Enum.any?(commands, fn
               <<0x52, 1, _::binary>> -> true
               _ -> false
             end)
    end
  end

  describe "update_tracking (shared)" do
    test "writes viewport tracking state into returned caches" do
      frame = build_frame_with_window(base_state(), viewport_top: 0)
      state = base_state()
      _layout = Layout.put(state)
      ctx = Context.from_editor_state(state)

      {caches, _font_registry} = Emit.emit(frame, ctx, nil, %Caches{})
      assert_receive {:"$gen_cast", {:send_commands, _}}

      assert is_map(caches.emit_prev_viewport_tops)
      assert is_map(caches.emit_prev_content_rects)
      assert is_map(caches.emit_prev_gutter_ws)
      assert is_map(caches.emit_prev_buf_versions)
    end
  end

  describe "send_title (shared)" do
    test "sends title command only when title changes" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      ctx = Context.from_editor_state(state)
      caches0 = %Caches{}

      {caches1, _font_registry} = Emit.emit(frame, ctx, nil, caches0)
      # Flush first commands + title
      assert_receive {:"$gen_cast", {:send_commands, _commands}}

      assert is_binary(caches1.last_title)

      # Emit again with same ctx; title should not be re-sent (cache hit)
      {caches2, _font_registry} = Emit.emit(frame, ctx, nil, caches1)
      assert_receive {:"$gen_cast", {:send_commands, _commands2}}

      assert caches2.last_title == caches1.last_title
    end
  end

  describe "send_window_bg (shared)" do
    test "sends background command only when theme changes" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      ctx = Context.from_editor_state(state)
      caches0 = %Caches{}

      {caches1, _font_registry} = Emit.emit(frame, ctx, nil, caches0)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      assert caches1.last_window_bg == state.theme.editor.bg

      # Emit again, should not re-send
      {caches2, _font_registry} = Emit.emit(frame, ctx, nil, caches1)
      assert_receive {:"$gen_cast", {:send_commands, _}}
      assert caches2.last_window_bg == caches1.last_window_bg
    end
  end
end
