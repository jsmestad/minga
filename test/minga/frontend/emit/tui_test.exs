defmodule Minga.Frontend.Emit.TUITest do
  @moduledoc """
  Tests for the TUI-specific Emit stage logic: scroll region detection,
  command building, and helper functions.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame, Overlay}
  alias Minga.Frontend.Emit
  alias Minga.Frontend.Emit.Context
  alias Minga.Frontend.Emit.TUI, as: EmitTUI

  import Minga.Editor.RenderPipeline.TestHelpers

  describe "build_commands via emit/2 (TUI path)" do
    setup do
      Process.delete(:emit_prev_viewport_tops)
      Process.delete(:emit_prev_content_rects)
      Process.delete(:emit_prev_gutter_ws)
      :ok
    end

    test "first frame always does full redraw (clear command present)" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      Emit.emit(frame, Context.from_editor_state(state))

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    test "converts frame to commands and sends to port_manager" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      Emit.emit(frame, Context.from_editor_state(state))

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert is_list(commands)
      assert Enum.all?(commands, &is_binary/1)
    end
  end

  describe "scroll region optimization" do
    setup do
      Process.delete(:emit_prev_viewport_tops)
      Process.delete(:emit_prev_content_rects)
      Process.delete(:emit_prev_gutter_ws)
      :ok
    end

    @tag skip: "scroll optimization disabled pending libvaxis buffer sync fix"
    test "uses scroll_region when viewport shifts by 1 line" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      Emit.emit(frame1, Context.from_editor_state(state1))
      assert_receive {:"$gen_cast", {:send_commands, _first_commands}}

      state2 = simulate_scroll(state, 1)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(state2))

      assert_receive {:"$gen_cast", {:send_commands, scroll_commands}}
      refute match?([<<0x12>> | _], scroll_commands)

      assert Enum.any?(scroll_commands, fn cmd ->
               match?(<<0x1B, _::binary>>, cmd)
             end)
    end

    @tag skip: "scroll optimization disabled pending libvaxis buffer sync fix"
    test "uses scroll_region when viewport shifts by 3 lines" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      Emit.emit(frame1, Context.from_editor_state(state1))
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 3)
      frame2 = build_frame_with_window(state2, viewport_top: 3)
      Emit.emit(frame2, Context.from_editor_state(state2))

      assert_receive {:"$gen_cast", {:send_commands, scroll_commands}}
      refute match?([<<0x12>> | _], scroll_commands)

      scroll_cmd =
        Enum.find(scroll_commands, fn cmd -> match?(<<0x1B, _::binary>>, cmd) end)

      assert <<0x1B, _top::16, _bottom::16, 3::16-signed>> = scroll_cmd
    end

    test "falls back to full redraw when delta exceeds 3 lines" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      Emit.emit(frame1, Context.from_editor_state(state1))
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 4)
      frame2 = build_frame_with_window(state2, viewport_top: 4)
      Emit.emit(frame2, Context.from_editor_state(state2))

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    test "falls back to full redraw when no scroll happened" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 5)
      frame1 = build_frame_with_window(state1, viewport_top: 5)
      Emit.emit(frame1, Context.from_editor_state(state1))
      assert_receive {:"$gen_cast", {:send_commands, _}}

      frame2 = build_frame_with_window(state1, viewport_top: 5)
      Emit.emit(frame2, Context.from_editor_state(state1))

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    @tag skip: "scroll optimization disabled pending libvaxis buffer sync fix"
    test "scroll_region uses negative delta for scrolling up" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 10)
      frame1 = build_frame_with_window(state1, viewport_top: 10)
      Emit.emit(frame1, Context.from_editor_state(state1))
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 8)
      frame2 = build_frame_with_window(state2, viewport_top: 8)
      Emit.emit(frame2, Context.from_editor_state(state2))

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
      Emit.emit(frame1, Context.from_editor_state(state1))
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(state2))

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert <<0x13>> = List.last(commands)
    end

    @tag skip: "scroll optimization disabled pending libvaxis buffer sync fix"
    test "always includes cursor commands in scroll region output" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      Emit.emit(frame1, Context.from_editor_state(state1))
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(state2))

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert Enum.any?(commands, fn cmd -> match?(<<0x11, _::binary>>, cmd) end)
      assert Enum.any?(commands, fn cmd -> match?(<<0x15, _::binary>>, cmd) end)
    end
  end

  describe "collect_chrome_draws/1" do
    test "concatenates all chrome frame fields" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        tab_bar: [DisplayList.draw(0, 0, "tab", face)],
        file_tree: [DisplayList.draw(1, 0, "tree", face)],
        agentic_view: [DisplayList.draw(2, 0, "agent_view", face)],
        separators: [DisplayList.draw(3, 0, "|", face)],
        status_bar: [DisplayList.draw(4, 0, "status", face)],
        agent_panel: [DisplayList.draw(5, 0, "panel", face)],
        minibuffer: [DisplayList.draw(6, 0, ":cmd", face)],
        splash: [DisplayList.draw(7, 0, "splash", face)]
      }

      draws = EmitTUI.collect_chrome_draws(frame)

      texts = Enum.map(draws, fn {_r, _c, text, _style} -> text end)
      assert "tab" in texts
      assert "tree" in texts
      assert "agent_view" in texts
      assert "|" in texts
      assert "status" in texts
      assert "panel" in texts
      assert ":cmd" in texts
      assert "splash" in texts
    end

    test "handles nil splash gracefully" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: nil
      }

      draws = EmitTUI.collect_chrome_draws(frame)
      assert is_list(draws)
    end
  end

  describe "collect_overlay_draws/1" do
    test "flattens overlay draw lists" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x3E4451)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        overlays: [
          %Overlay{draws: [DisplayList.draw(5, 10, "hover", face)]},
          %Overlay{
            draws: [DisplayList.draw(6, 10, "sig", face), DisplayList.draw(7, 10, "help", face)]
          }
        ]
      }

      draws = EmitTUI.collect_overlay_draws(frame)
      texts = Enum.map(draws, fn {_r, _c, text, _style} -> text end)
      assert length(draws) == 3
      assert "hover" in texts
      assert "sig" in texts
      assert "help" in texts
    end

    test "returns empty list for frame with no overlays" do
      frame = %Frame{cursor: Cursor.new(0, 0, :block)}
      assert EmitTUI.collect_overlay_draws(frame) == []
    end
  end

  describe "compute_new_rows/1" do
    test "returns bottom rows for positive delta (scrolled down)" do
      delta = %{delta: 2, content_rect: {0, 0, 80, 24}}
      # bottom = 0 + 24 - 1 = 23, new rows = (23 - 2 + 1)..23 = 22..23
      assert EmitTUI.compute_new_rows(delta) == 22..23
    end

    test "returns top rows for negative delta (scrolled up)" do
      delta = %{delta: -2, content_rect: {0, 0, 80, 24}}
      assert EmitTUI.compute_new_rows(delta) == 0..1
    end

    test "handles content_rect with non-zero row offset" do
      delta = %{delta: 1, content_rect: {5, 0, 80, 20}}
      # Bottom row is 5 + 20 - 1 = 24, new row is 24..24
      assert EmitTUI.compute_new_rows(delta) == 24..24
    end
  end

  describe "filter_layer_by_ranges/2" do
    test "returns only draws in the specified row ranges" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)

      layer = %{
        0 => [{0, "line0", face}],
        1 => [{0, "line1", face}],
        5 => [{0, "line5", face}],
        8 => [{0, "line8", face}],
        9 => [{0, "line9", face}]
      }

      result = EmitTUI.filter_layer_by_ranges(layer, [7..9])
      texts = Enum.map(result, fn {_r, _c, text, _style} -> text end)
      assert length(result) == 2
      assert "line8" in texts
      assert "line9" in texts
    end

    test "returns empty list when no rows match" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)
      layer = %{0 => [{0, "line0", face}]}

      assert EmitTUI.filter_layer_by_ranges(layer, [5..10]) == []
    end

    test "handles multiple ranges" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)

      layer = %{
        0 => [{0, "line0", face}],
        3 => [{0, "line3", face}],
        7 => [{0, "line7", face}]
      }

      result = EmitTUI.filter_layer_by_ranges(layer, [0..0, 7..7])
      texts = Enum.map(result, fn {_r, _c, text, _style} -> text end)
      assert length(result) == 2
      assert "line0" in texts
      assert "line7" in texts
    end

    test "handles empty layer" do
      assert EmitTUI.filter_layer_by_ranges(%{}, [0..5]) == []
    end
  end
end
