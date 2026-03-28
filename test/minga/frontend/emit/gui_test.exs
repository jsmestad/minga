defmodule Minga.Frontend.Emit.GUITest do
  @moduledoc """
  Tests for the GUI-specific Emit stage logic: frame filtering and
  integration with the emit dispatcher.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame, Overlay, WindowFrame}
  alias Minga.Frontend.Emit
  alias Minga.Frontend.Emit.Context
  alias Minga.Frontend.Emit.GUI, as: EmitGUI

  import Minga.Editor.RenderPipeline.TestHelpers

  describe "filter_frame_for_gui/1" do
    test "clears splash and passes through already-empty chrome fields" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(5, 0, "splash", face)]
      }

      filtered = EmitGUI.filter_frame_for_gui(frame)

      # Splash is cleared (comes from Renderer, not Chrome.GUI)
      assert filtered.splash == nil
      # Chrome fields are already [] from Chrome.GUI, filter doesn't touch them
      assert filtered.tab_bar == []
      assert filtered.file_tree == []
      assert filtered.status_bar == []
    end

    test "passes through minibuffer, separators, and overlays unchanged" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)
      hover_face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x3E4451)

      # In practice Chrome.GUI produces [] for all of these, but
      # filter_frame_for_gui does not strip them (it only strips
      # SwiftUI-owned chrome fields). This test confirms passthrough.
      minibuffer_draws = [DisplayList.draw(24, 0, ":write", face)]
      separator_draws = [DisplayList.draw(0, 40, "│", face)]
      overlay_draws = [DisplayList.draw(5, 10, "hover info", hover_face)]

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        minibuffer: minibuffer_draws,
        separators: separator_draws,
        overlays: [%Overlay{draws: overlay_draws}]
      }

      filtered = EmitGUI.filter_frame_for_gui(frame)

      assert filtered.minibuffer == minibuffer_draws
      assert filtered.separators == separator_draws
      assert filtered.overlays == [%Overlay{draws: overlay_draws}]
    end

    test "strips gutter from all window frames" do
      face = Minga.Core.Face.new(fg: 0x5B6268, bg: 0x282C34)

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

    test "preserves lines and tilde_lines when no semantic content" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)
      tilde_face = Minga.Core.Face.new(fg: 0x5B6268, bg: 0x282C34)

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

    test "strips lines and tilde_lines from windows with semantic content" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)

      content_layer = DisplayList.draws_to_layer([DisplayList.draw(0, 4, "hello world", face)])
      tilde_layer = DisplayList.draws_to_layer([DisplayList.draw(5, 0, "~", face)])

      semantic = %Minga.Editor.SemanticWindow{
        window_id: 1,
        rows: [],
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block
      }

      wf = %WindowFrame{
        rect: {0, 0, 80, 20},
        gutter: DisplayList.draws_to_layer([DisplayList.draw(0, 0, "  1 ", face)]),
        lines: content_layer,
        tilde_lines: tilde_layer,
        modeline: %{},
        cursor: nil,
        semantic: semantic
      }

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        windows: [wf]
      }

      filtered = EmitGUI.filter_frame_for_gui(frame)
      filtered_wf = hd(filtered.windows)

      assert filtered_wf.lines == %{}
      assert filtered_wf.tilde_lines == %{}
      assert filtered_wf.gutter == %{}
    end

    test "mixed windows: semantic gets stripped, non-semantic preserved" do
      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)
      content = DisplayList.draws_to_layer([DisplayList.draw(0, 4, "text", face)])

      semantic = %Minga.Editor.SemanticWindow{
        window_id: 1,
        rows: [],
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block
      }

      buffer_wf = %WindowFrame{
        rect: {0, 0, 40, 20},
        lines: content,
        tilde_lines: %{},
        modeline: %{},
        cursor: nil,
        semantic: semantic
      }

      chat_wf = %WindowFrame{
        rect: {0, 40, 40, 20},
        lines: content,
        tilde_lines: %{},
        modeline: %{},
        cursor: nil,
        semantic: nil
      }

      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        windows: [buffer_wf, chat_wf]
      }

      filtered = EmitGUI.filter_frame_for_gui(frame)
      [filtered_buf, filtered_chat] = filtered.windows

      # Buffer window: lines stripped (semantic provides content via 0x80)
      assert filtered_buf.lines == %{}

      # Chat window: lines preserved (no semantic content)
      assert filtered_chat.lines == content
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
    test "GUI path strips splash from draw commands" do
      state = gui_state(rows: 24, cols: 80, content: long_content(20))

      frame = build_frame_with_window(state, viewport_top: 0)

      face = Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x21242B)

      frame_with_splash = %{
        frame
        | splash: [DisplayList.draw(5, 0, "Welcome to Minga", face)]
      }

      Emit.emit(frame_with_splash, Context.from_editor_state(state))

      assert_receive {:"$gen_cast", {:send_commands, commands}}

      draw_commands = Enum.filter(commands, &match?(<<0x10, _::binary>>, &1))

      # Splash should NOT appear as draw_text (GUI renders natively)
      refute Enum.any?(draw_commands, fn <<0x10, _row::16, _col::16, _fg::24, _bg::24, _attrs::8,
                                           len::16, text::binary-size(len)>> ->
               text == "Welcome to Minga"
             end),
             "Splash text should not appear in GUI draw commands"
    end

    test "GUI path preserves Metal-rendered overlays" do
      state = gui_state()

      frame = build_frame_with_window(state, viewport_top: 0)

      hover_draw =
        DisplayList.draw(5, 10, "hover info", Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x3E4451))

      frame_with_overlay = %{
        frame
        | overlays: [%Overlay{draws: [hover_draw]}]
      }

      Emit.emit(frame_with_overlay, Context.from_editor_state(state))

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      draw_commands = Enum.filter(commands, &match?(<<0x10, _::binary>>, &1))

      assert Enum.any?(draw_commands, fn <<0x10, _row::16, _col::16, _fg::24, _bg::24, _attrs::8,
                                           len::16, text::binary-size(len)>> ->
               text == "hover info"
             end)
    end
  end
end
