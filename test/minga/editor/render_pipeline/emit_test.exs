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
end
