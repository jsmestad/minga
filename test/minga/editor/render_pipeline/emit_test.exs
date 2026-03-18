defmodule Minga.Editor.RenderPipeline.EmitTest do
  @moduledoc """
  Tests for the Emit stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame, WindowFrame}
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline.Emit

  import Minga.Editor.RenderPipeline.TestHelpers

  alias Minga.Port.Capabilities

  describe "emit/2" do
    test "converts frame to commands and sends to port_manager" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      assert :ok = Emit.emit(frame, state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert is_list(commands)
      assert Enum.all?(commands, &is_binary/1)
    end

    test "first frame always does full redraw (clear command present)" do
      # Clear any previous tracking state
      Process.delete(:emit_prev_viewport_tops)
      Process.delete(:emit_prev_content_rects)
      Process.delete(:emit_prev_gutter_ws)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      assert :ok = Emit.emit(frame, state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      # First command should be clear (0x12)
      assert [<<0x12>> | _] = commands
    end
  end

  describe "scroll region optimization" do
    setup do
      # Clear tracking state between tests
      Process.delete(:emit_prev_viewport_tops)
      Process.delete(:emit_prev_content_rects)
      Process.delete(:emit_prev_gutter_ws)
      :ok
    end

    @tag skip: "scroll optimization disabled pending libvaxis buffer sync fix"
    test "uses scroll_region when viewport shifts by 1 line" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      # First emit: establishes tracking state (full redraw)
      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      assert :ok = Emit.emit(frame1, state1)
      assert_receive {:"$gen_cast", {:send_commands, _first_commands}}

      # Simulate scrolling down by 1 line
      state2 = simulate_scroll(state, 1)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      assert :ok = Emit.emit(frame2, state2)

      assert_receive {:"$gen_cast", {:send_commands, scroll_commands}}
      # Should NOT start with clear (0x12)
      refute match?([<<0x12>> | _], scroll_commands)
      # Should contain a scroll_region command (0x1B)
      assert Enum.any?(scroll_commands, fn cmd ->
               match?(<<0x1B, _::binary>>, cmd)
             end)
    end

    @tag skip: "scroll optimization disabled pending libvaxis buffer sync fix"
    test "uses scroll_region when viewport shifts by 3 lines" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      assert :ok = Emit.emit(frame1, state1)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 3)
      frame2 = build_frame_with_window(state2, viewport_top: 3)
      assert :ok = Emit.emit(frame2, state2)

      assert_receive {:"$gen_cast", {:send_commands, scroll_commands}}
      refute match?([<<0x12>> | _], scroll_commands)

      # Verify the scroll_region delta is 3
      scroll_cmd =
        Enum.find(scroll_commands, fn cmd -> match?(<<0x1B, _::binary>>, cmd) end)

      assert <<0x1B, _top::16, _bottom::16, 3::16-signed>> = scroll_cmd
    end

    test "falls back to full redraw when delta exceeds 3 lines" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      assert :ok = Emit.emit(frame1, state1)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 4)
      frame2 = build_frame_with_window(state2, viewport_top: 4)
      assert :ok = Emit.emit(frame2, state2)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      # Should start with clear (full redraw)
      assert [<<0x12>> | _] = commands
    end

    test "falls back to full redraw when no scroll happened" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 5)
      frame1 = build_frame_with_window(state1, viewport_top: 5)
      assert :ok = Emit.emit(frame1, state1)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      # Same viewport top: no scroll, full redraw (no deltas collected)
      frame2 = build_frame_with_window(state1, viewport_top: 5)
      assert :ok = Emit.emit(frame2, state1)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    @tag skip: "scroll optimization disabled pending libvaxis buffer sync fix"
    test "scroll_region uses negative delta for scrolling up" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      # Start at line 10
      state1 = seed_state(state, 10)
      frame1 = build_frame_with_window(state1, viewport_top: 10)
      assert :ok = Emit.emit(frame1, state1)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      # Scroll up by 2
      state2 = simulate_scroll(state, 8)
      frame2 = build_frame_with_window(state2, viewport_top: 8)
      assert :ok = Emit.emit(frame2, state2)

      assert_receive {:"$gen_cast", {:send_commands, scroll_commands}}
      refute match?([<<0x12>> | _], scroll_commands)

      scroll_cmd =
        Enum.find(scroll_commands, fn cmd -> match?(<<0x1B, _::binary>>, cmd) end)

      assert <<0x1B, _top::16, _bottom::16, delta::16-signed>> = scroll_cmd
      assert delta == -2
    end

    @tag skip: "scroll optimization disabled pending libvaxis buffer sync fix"
    test "always includes batch_end in scroll region commands" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      assert :ok = Emit.emit(frame1, state1)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      assert :ok = Emit.emit(frame2, state2)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      # Last command should be batch_end (0x13)
      assert <<0x13>> = List.last(commands)
    end

    @tag skip: "scroll optimization disabled pending libvaxis buffer sync fix"
    test "always includes cursor commands in scroll region output" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      assert :ok = Emit.emit(frame1, state1)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      assert :ok = Emit.emit(frame2, state2)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      # Should contain set_cursor (0x11) and set_cursor_shape (0x15)
      assert Enum.any?(commands, fn cmd -> match?(<<0x11, _::binary>>, cmd) end)
      assert Enum.any?(commands, fn cmd -> match?(<<0x15, _::binary>>, cmd) end)
    end
  end

  describe "GUI frame filtering" do
    test "TUI and GUI paths produce identical editor content window draws" do
      state = base_state(rows: 24, cols: 80, content: long_content(20))

      # Build a frame with window content, file tree, and tab bar draws
      frame = build_frame_with_window(state, viewport_top: 0)

      file_tree_draws = [DisplayList.draw(0, 0, "src/", fg: 0xBBC2CF, bg: 0x21242B)]
      tab_bar_draws = [DisplayList.draw(0, 0, " main.ex ", fg: 0xBBC2CF, bg: 0x21242B)]

      frame_with_chrome = %{
        frame
        | file_tree: file_tree_draws,
          tab_bar: tab_bar_draws,
          agent_panel: [DisplayList.draw(0, 0, "agent", fg: 0xBBC2CF, bg: 0x21242B)]
      }

      # TUI path: gets everything
      tui_commands = DisplayList.to_commands(frame_with_chrome)

      # GUI path: filters out SwiftUI-handled fields, then same to_commands
      gui_frame = %{
        frame_with_chrome
        | tab_bar: [],
          file_tree: [],
          agent_panel: [],
          agentic_view: [],
          splash: nil
      }

      gui_commands = DisplayList.to_commands(gui_frame)

      # Both should have clear, cursor, and batch_end
      assert [<<0x12>> | _] = tui_commands
      assert [<<0x12>> | _] = gui_commands

      # GUI should have fewer commands (no file tree, tab bar, agent panel draws)
      assert length(gui_commands) < length(tui_commands)

      # Extract just the draw commands (opcode 0x10) from both
      tui_draws = Enum.filter(tui_commands, &match?(<<0x10, _::binary>>, &1))
      gui_draws = Enum.filter(gui_commands, &match?(<<0x10, _::binary>>, &1))

      # GUI should have exactly 3 fewer draws (file_tree + tab_bar + agent_panel)
      assert length(tui_draws) - length(gui_draws) == 3

      # All GUI draws should be present in TUI draws (same window content)
      for draw <- gui_draws do
        assert draw in tui_draws, "GUI draw command not found in TUI commands"
      end
    end

    test "GUI emit path uses filtered frame via to_commands" do
      state = base_state()
      gui_state = %{state | capabilities: %Capabilities{frontend_type: :native_gui}}

      frame = build_frame_with_window(gui_state, viewport_top: 0)

      frame_with_chrome = %{
        frame
        | file_tree: [DisplayList.draw(0, 0, "src/", fg: 0xBBC2CF, bg: 0x21242B)],
          tab_bar: [DisplayList.draw(0, 0, " tab ", fg: 0xBBC2CF, bg: 0x21242B)]
      }

      assert :ok = Emit.emit(frame_with_chrome, gui_state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert is_list(commands)

      # Should have clear at the start
      assert [<<0x12>> | _] = commands

      # Should NOT contain file tree or tab bar draw commands.
      # The file tree draw is at row=0, col=0 with "src/" text.
      # The tab bar draw is at row=0, col=0 with " tab " text.
      draw_commands = Enum.filter(commands, &match?(<<0x10, _::binary>>, &1))

      refute Enum.any?(draw_commands, fn <<0x10, _row::16, _col::16, _fg::24, _bg::24, _attrs::8,
                                           len::16, text::binary-size(len)>> ->
               text == "src/" or text == " tab "
             end)
    end

    test "GUI path strips per-window modeline draws" do
      state = base_state()
      gui_state = %{state | capabilities: %Capabilities{frontend_type: :native_gui}}

      frame = build_frame_with_modeline(gui_state, viewport_top: 0)

      assert :ok = Emit.emit(frame, gui_state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}

      # Extract all draw commands
      draw_commands = Enum.filter(commands, &match?(<<0x10, _::binary>>, &1))

      # Modeline text (" NORMAL " and " main.ex ") should NOT appear
      refute Enum.any?(draw_commands, fn <<0x10, _row::16, _col::16, _fg::24, _bg::24, _attrs::8,
                                           len::16, text::binary-size(len)>> ->
               text == " NORMAL " or text == " main.ex "
             end),
             "Modeline draws should be stripped from GUI frame"
    end

    test "GUI path preserves Metal-rendered overlays (hover, signature help)" do
      state = base_state()
      gui_state = %{state | capabilities: %Capabilities{frontend_type: :native_gui}}

      frame = build_frame_with_window(gui_state, viewport_top: 0)
      hover_draw = DisplayList.draw(5, 10, "hover info", fg: 0xBBC2CF, bg: 0x3E4451)

      frame_with_overlay = %{
        frame
        | overlays: [%DisplayList.Overlay{draws: [hover_draw]}]
      }

      assert :ok = Emit.emit(frame_with_overlay, gui_state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      draw_commands = Enum.filter(commands, &match?(<<0x10, _::binary>>, &1))

      # The hover overlay draw should be present in the output
      assert Enum.any?(draw_commands, fn <<0x10, _row::16, _col::16, _fg::24, _bg::24, _attrs::8,
                                           len::16, text::binary-size(len)>> ->
               text == "hover info"
             end)
    end
  end

  # ── Test helpers ──────────────────────────────────────────────────────────

  defp long_content(n) do
    Enum.map_join(1..n, "\n", fn i -> "line #{i}: content here for testing" end)
  end

  # Sets up the window tracking fields as if a render pass completed at the given
  # viewport top. Ensures gutter_w and buf_version are consistent across frames.
  defp simulate_scroll(state, new_top) do
    win_id = state.windows.active
    window = Map.get(state.windows.map, win_id)

    updated_window = %{
      window
      | last_viewport_top: new_top,
        last_gutter_w: 4,
        last_buf_version: 1,
        last_line_count: 100,
        last_cursor_line: new_top
    }

    new_map = Map.put(state.windows.map, win_id, updated_window)
    %{state | windows: %{state.windows | map: new_map}}
  end

  # Seeds the initial tracking state so the first frame has consistent values.
  # Without this, the sentinel values (-1) cause spurious gutter-width mismatches.
  defp seed_state(state, viewport_top) do
    simulate_scroll(state, viewport_top)
  end

  defp build_frame_with_window(state, opts) do
    viewport_top = Keyword.get(opts, :viewport_top, 0)
    layout = Layout.put(state) |> Layout.get()

    win_id = state.windows.active
    win_layout = Map.get(layout.window_layouts, win_id)
    {_row, _col, width, height} = win_layout.content

    # Build some content draws for the visible area
    content_draws =
      for row <- 0..(height - 1) do
        DisplayList.draw(row, 4, "line #{viewport_top + row}: content",
          fg: 0xBBC2CF,
          bg: 0x282C34
        )
      end

    gutter_draws =
      for row <- 0..(height - 1) do
        DisplayList.draw(row, 0, String.pad_leading("#{viewport_top + row + 1}", 3) <> " ",
          fg: 0x5B6268,
          bg: 0x282C34
        )
      end

    win_frame = %WindowFrame{
      rect: {0, 0, width, height},
      gutter: DisplayList.draws_to_layer(gutter_draws),
      lines: DisplayList.draws_to_layer(content_draws),
      tilde_lines: %{},
      modeline: %{},
      cursor: nil
    }

    %Frame{
      cursor: Cursor.new(0, 4, :block),
      windows: [win_frame],
      minibuffer: [DisplayList.draw(height + 1, 0, " ", fg: 0xBBC2CF, bg: 0x282C34)]
    }
  end

  defp build_frame_with_modeline(state, opts) do
    frame = build_frame_with_window(state, opts)

    modeline_draws = [
      DisplayList.draw(0, 0, " NORMAL ", fg: 0x21242B, bg: 0x51AFEF),
      DisplayList.draw(0, 9, " main.ex ", fg: 0xBBC2CF, bg: 0x21242B)
    ]

    windows =
      Enum.map(frame.windows, fn wf ->
        %{wf | modeline: DisplayList.draws_to_layer(modeline_draws)}
      end)

    %{frame | windows: windows}
  end
end
