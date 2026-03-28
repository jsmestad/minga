defmodule Minga.Frontend.EmitTest do
  @moduledoc """
  Tests for the Emit stage dispatcher and shared helpers.

  TUI-specific tests are in `emit/tui_test.exs`.
  GUI-specific tests are in `emit/gui_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame}
  alias Minga.Editor.Layout
  alias Minga.Frontend.Emit
  alias Minga.Frontend.Emit.Context

  import Minga.Editor.RenderPipeline.TestHelpers

  describe "emit/2 dispatching" do
    test "TUI path produces commands starting with clear" do
      Process.delete(:emit_prev_viewport_tops)
      Process.delete(:emit_prev_content_rects)
      Process.delete(:emit_prev_gutter_ws)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
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
  end

  describe "update_tracking (shared)" do
    test "writes viewport tracking state to process dictionary" do
      Process.delete(:emit_prev_viewport_tops)
      Process.delete(:emit_prev_content_rects)
      Process.delete(:emit_prev_gutter_ws)
      Process.delete(:emit_prev_buf_versions)

      frame = build_frame_with_window(base_state(), viewport_top: 0)
      state = base_state()
      _layout = Layout.put(state)
      ctx = Context.from_editor_state(state)

      Emit.emit(frame, ctx)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      assert is_map(Process.get(:emit_prev_viewport_tops))
      assert is_map(Process.get(:emit_prev_content_rects))
      assert is_map(Process.get(:emit_prev_gutter_ws))
      assert is_map(Process.get(:emit_prev_buf_versions))
    end
  end

  describe "send_title (shared)" do
    test "sends title command only when title changes" do
      Process.delete(:last_title)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      # Flush first commands + title
      assert_receive {:"$gen_cast", {:send_commands, _commands}}

      # There may be a title command sent separately
      title_sent_first = Process.get(:last_title)
      assert is_binary(title_sent_first)

      # Emit again with same ctx, title should not be re-sent
      Emit.emit(frame, ctx)
      assert_receive {:"$gen_cast", {:send_commands, _commands2}}

      # Title in process dictionary unchanged
      assert Process.get(:last_title) == title_sent_first
    end
  end

  describe "send_window_bg (shared)" do
    test "sends background command only when theme changes" do
      Process.delete(:last_window_bg)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      assert_receive {:"$gen_cast", {:send_commands, _}}
      bg = Process.get(:last_window_bg)
      assert bg == state.theme.editor.bg

      # Emit again, should not re-send
      Emit.emit(frame, ctx)
      assert_receive {:"$gen_cast", {:send_commands, _}}
      assert Process.get(:last_window_bg) == bg
    end
  end
end
