defmodule Minga.Editor.RenderPipeline.Emit.GUITest do
  @moduledoc """
  Tests for the GUI-specific Emit stage logic: frame filtering and
  integration with the emit dispatcher.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame, Overlay, WindowFrame}
  alias Minga.Editor.RenderPipeline.Emit
  alias Minga.Editor.RenderPipeline.Emit.GUI, as: EmitGUI

  import Minga.Editor.RenderPipeline.TestHelpers

  describe "filter_frame_for_gui/1" do
    test "zeroes SwiftUI-owned fields" do
      face = Minga.Face.new(fg: 0xBBC2CF, bg: 0x282C34)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        tab_bar: [DisplayList.draw(0, 0, "tab", face)],
        file_tree: [DisplayList.draw(1, 0, "tree", face)],
        agent_panel: [DisplayList.draw(2, 0, "panel", face)],
        agentic_view: [DisplayList.draw(3, 0, "view", face)],
        status_bar: [DisplayList.draw(4, 0, "status", face)],
        splash: [DisplayList.draw(5, 0, "splash", face)]
      }

      filtered = EmitGUI.filter_frame_for_gui(frame)

      assert filtered.tab_bar == []
      assert filtered.file_tree == []
      assert filtered.agent_panel == []
      assert filtered.agentic_view == []
      assert filtered.status_bar == []
      assert filtered.splash == nil
    end

    test "preserves minibuffer and overlays" do
      face = Minga.Face.new(fg: 0xBBC2CF, bg: 0x282C34)
      hover_face = Minga.Face.new(fg: 0xBBC2CF, bg: 0x3E4451)

      minibuffer_draws = [DisplayList.draw(24, 0, ":write", face)]
      overlay_draws = [DisplayList.draw(5, 10, "hover info", hover_face)]

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        minibuffer: minibuffer_draws,
        overlays: [%Overlay{draws: overlay_draws}]
      }

      filtered = EmitGUI.filter_frame_for_gui(frame)

      assert filtered.minibuffer == minibuffer_draws
      assert length(filtered.overlays) == 1
      assert hd(filtered.overlays).draws == overlay_draws
    end

    test "strips gutter from all window frames" do
      face = Minga.Face.new(fg: 0x5B6268, bg: 0x282C34)

      wf1 = %WindowFrame{
        rect: {0, 0, 40, 20},
        gutter: DisplayList.draws_to_layer([DisplayList.draw(0, 0, "  1 ", face)]),
        lines: %{},
        tilde_lines: %{},
        modeline: %{},
        cursor: nil
      }

      wf2 = %WindowFrame{
        rect: {0, 40, 40, 20},
        gutter: DisplayList.draws_to_layer([DisplayList.draw(0, 0, "  1 ", face)]),
        lines: %{},
        tilde_lines: %{},
        modeline: %{},
        cursor: nil
      }

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        windows: [wf1, wf2]
      }

      filtered = EmitGUI.filter_frame_for_gui(frame)

      assert length(filtered.windows) == 2
      assert Enum.all?(filtered.windows, fn wf -> wf.gutter == %{} end)
    end

    test "preserves window content lines and tilde_lines" do
      face = Minga.Face.new(fg: 0xBBC2CF, bg: 0x282C34)
      tilde_face = Minga.Face.new(fg: 0x5B6268, bg: 0x282C34)

      content_layer = DisplayList.draws_to_layer([DisplayList.draw(0, 4, "hello world", face)])
      tilde_layer = DisplayList.draws_to_layer([DisplayList.draw(5, 0, "~", tilde_face)])

      wf = %WindowFrame{
        rect: {0, 0, 80, 20},
        gutter: DisplayList.draws_to_layer([DisplayList.draw(0, 0, "  1 ", face)]),
        lines: content_layer,
        tilde_lines: tilde_layer,
        modeline: %{},
        cursor: nil
      }

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        windows: [wf]
      }

      filtered = EmitGUI.filter_frame_for_gui(frame)
      filtered_wf = hd(filtered.windows)

      assert filtered_wf.lines == content_layer
      assert filtered_wf.tilde_lines == tilde_layer
    end

    test "handles empty frame (no windows, no chrome)" do
      frame = %Frame{cursor: Cursor.new(0, 0, :block)}

      filtered = EmitGUI.filter_frame_for_gui(frame)
      assert filtered.windows == []
      assert filtered.tab_bar == []
      assert filtered.splash == nil
    end
  end

  describe "emit/2 GUI integration" do
    test "GUI path strips SwiftUI-owned chrome from draw commands" do
      state = gui_state(rows: 24, cols: 80, content: long_content(20))

      frame = build_frame_with_window(state, viewport_top: 0)

      face = Minga.Face.new(fg: 0xBBC2CF, bg: 0x21242B)

      frame_with_chrome = %{
        frame
        | file_tree: [DisplayList.draw(0, 0, "src/", face)],
          tab_bar: [DisplayList.draw(0, 0, " main.ex ", face)],
          agent_panel: [DisplayList.draw(0, 0, "agent", face)],
          minibuffer: [
            DisplayList.draw(24, 0, ":quit", Minga.Face.new(fg: 0xBBC2CF, bg: 0x282C34))
          ]
      }

      Emit.emit(frame_with_chrome, state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}

      draw_commands = Enum.filter(commands, &match?(<<0x10, _::binary>>, &1))

      # SwiftUI-owned chrome should NOT appear
      for chrome_text <- ["src/", " main.ex ", "agent"] do
        refute Enum.any?(draw_commands, fn <<0x10, _row::16, _col::16, _fg::24, _bg::24,
                                             _attrs::8, len::16, text::binary-size(len)>> ->
                 text == chrome_text
               end),
               "SwiftUI chrome '#{chrome_text}' should not appear in GUI draw commands"
      end

      # Minibuffer passes through
      assert Enum.any?(draw_commands, fn <<0x10, _row::16, _col::16, _fg::24, _bg::24, _attrs::8,
                                           len::16, text::binary-size(len)>> ->
               text == ":quit"
             end)
    end

    test "GUI path preserves Metal-rendered overlays" do
      state = gui_state()

      frame = build_frame_with_window(state, viewport_top: 0)

      hover_draw =
        DisplayList.draw(5, 10, "hover info", Minga.Face.new(fg: 0xBBC2CF, bg: 0x3E4451))

      frame_with_overlay = %{
        frame
        | overlays: [%Overlay{draws: [hover_draw]}]
      }

      Emit.emit(frame_with_overlay, state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      draw_commands = Enum.filter(commands, &match?(<<0x10, _::binary>>, &1))

      assert Enum.any?(draw_commands, fn <<0x10, _row::16, _col::16, _fg::24, _bg::24, _attrs::8,
                                           len::16, text::binary-size(len)>> ->
               text == "hover info"
             end)
    end
  end
end
