defmodule MingaEditor.Frontend.EmitTest do
  @moduledoc """
  Tests for the Emit stage dispatcher and shared helpers.

  TUI-specific tests are in `emit/tui_test.exs`.
  GUI-specific tests are in `emit/gui_test.exs`.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, Frame}
  alias MingaEditor.Layout
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Renderer.Caches

  import MingaEditor.RenderPipeline.TestHelpers

  describe "emit/2 dispatching" do
    test "TUI path produces commands starting with clear" do
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

    test "TUI path omits clear for an undamaged frame" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")],
        damage: false
      }

      state = base_state()
      ctx = Context.from_editor_state(state)
      Emit.emit(frame, ctx)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      refute Enum.member?(commands, <<0x12>>)
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
    test "writes viewport tracking state into returned caches" do
      frame = build_frame_with_window(base_state(), viewport_top: 0)
      state = base_state()
      _layout = Layout.put(state)
      ctx = Context.from_editor_state(state)

      caches = Emit.emit(frame, ctx, nil, %Caches{})
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

      caches1 = Emit.emit(frame, ctx, nil, caches0)
      # Flush first commands + title
      assert_receive {:"$gen_cast", {:send_commands, _commands}}

      assert is_binary(caches1.last_title)

      # Emit again with same ctx; title should not be re-sent (cache hit)
      caches2 = Emit.emit(frame, ctx, nil, caches1)
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

      caches1 = Emit.emit(frame, ctx, nil, caches0)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      assert caches1.last_window_bg == state.theme.editor.bg

      # Emit again, should not re-send
      caches2 = Emit.emit(frame, ctx, nil, caches1)
      assert_receive {:"$gen_cast", {:send_commands, _}}
      assert caches2.last_window_bg == caches1.last_window_bg
    end
  end
end
