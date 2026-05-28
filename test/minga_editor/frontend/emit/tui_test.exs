defmodule MingaEditor.Frontend.Emit.TUITest do
  @moduledoc """
  Tests for the TUI-specific Emit stage logic: scroll region detection,
  command building, and helper functions.
  """

  use ExUnit.Case, async: true

  alias Minga.RenderModel, as: CoreRenderModel
  alias Minga.RenderModel.Cursor, as: RenderCursor
  alias Minga.RenderModel.Window, as: RenderWindow
  alias Minga.RenderModel.Window.Gutter
  alias Minga.RenderModel.Window.GutterEntry
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Row
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, Frame, Overlay, WindowFrame}
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Emit.TUI, as: EmitTUI
  alias MingaEditor.Frontend.Protocol

  import MingaEditor.RenderPipeline.TestHelpers

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

  describe "render model TUI output" do
    test "full redraw takes buffer content from render model instead of legacy window layers" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        windows: [
          %WindowFrame{
            rect: {0, 0, 20, 1},
            lines: DisplayList.draws_to_layer([DisplayList.draw(0, 0, "legacy")]),
            gutter: %{},
            tilde_lines: %{},
            modeline: %{}
          }
        ]
      }

      render_model = render_model_with_rows(["model"])

      commands =
        EmitTUI.build_commands_from_deltas(
          render_model,
          frame,
          Context.from_editor_state(base_state()),
          nil
        )

      texts = decoded_draw_texts(commands)

      assert "model" in texts
      refute "legacy" in texts
    end

    test "scroll redraw filters newly exposed rows from render model cells" do
      frame = %Frame{cursor: Cursor.new(0, 0, :block)}
      render_model = render_model_with_rows(["row0", "row1", "row2"])

      commands =
        EmitTUI.build_commands_from_deltas(
          render_model,
          frame,
          Context.from_editor_state(base_state()),
          [
            %{win_id: 1, delta: 1, content_rect: {0, 0, 20, 3}}
          ]
        )

      texts = decoded_draw_texts(commands)

      assert "row2" in texts
      refute "row0" in texts
      refute "row1" in texts
    end

    test "scroll redraw includes exposed gutter cells and tilde filler from render model" do
      frame = %Frame{cursor: Cursor.new(0, 0, :block)}
      render_model = render_model_with_gutter_and_tilde()

      commands =
        EmitTUI.build_commands_from_deltas(
          render_model,
          frame,
          Context.from_editor_state(base_state()),
          [
            %{win_id: 1, delta: 2, content_rect: {0, 0, 20, 3}}
          ]
        )

      draws = decoded_draws(commands)

      assert Enum.any?(draws, &(&1.row == 1 and &1.col == 0 and &1.text == "E "))
      assert Enum.any?(draws, &(&1.row == 1 and &1.col == 4 and &1.text == "row1"))
      assert Enum.any?(draws, &(&1.row == 2 and &1.col == 4 and &1.text == "~"))
      refute Enum.any?(draws, &(&1.row == 0 and &1.text == "row0"))
    end

    test "scroll redraw clears cursorline redraw rows before drawing model content" do
      frame = %Frame{cursor: Cursor.new(0, 0, :block)}
      render_model = render_model_with_rows(["row0", "x", "row2"])

      commands =
        EmitTUI.build_commands_from_deltas(
          render_model,
          frame,
          Context.from_editor_state(base_state()),
          [
            %{win_id: 1, delta: 1, content_rect: {0, 0, 20, 3}, redraw_rows: [1]}
          ]
        )

      draws = decoded_draws(commands)

      clear_index =
        Enum.find_index(
          draws,
          &(&1.row == 1 and &1.col == 0 and &1.text == String.duplicate(" ", 20))
        )

      content_index = Enum.find_index(draws, &(&1.row == 1 and &1.col == 0 and &1.text == "x"))

      assert is_integer(clear_index)
      assert is_integer(content_index)
      assert clear_index < content_index
    end

    test "scroll redraw also repaints shifted previous and current cursorline rows" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = state |> seed_state(0) |> set_cached_cursor_line(5)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = state |> simulate_scroll(1) |> set_cached_cursor_line(6)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      texts = decoded_draw_texts(commands)

      refute match?([<<0x12>> | _], commands)
      assert "line 6: content" in texts
      assert "line 7: content" in texts
    end
  end

  describe "scroll region optimization" do
    setup do
      Process.delete(:emit_prev_viewport_tops)
      Process.delete(:emit_prev_content_rects)
      Process.delete(:emit_prev_gutter_ws)
      :ok
    end

    test "uses scroll_region when viewport shifts by 1 line" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _first_commands}}

      state2 = simulate_scroll(state, 1)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, scroll_commands}}
      refute match?([<<0x12>> | _], scroll_commands)

      assert Enum.any?(scroll_commands, fn cmd ->
               match?(<<0x1B, _::binary>>, cmd)
             end)
    end

    test "uses scroll_region when viewport shifts by 3 lines" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 3)
      frame2 = build_frame_with_window(state2, viewport_top: 3)
      Emit.emit(frame2, Context.from_editor_state(state2), nil, caches)

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
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 4)
      frame2 = build_frame_with_window(state2, viewport_top: 4)
      Emit.emit(frame2, Context.from_editor_state(state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    test "falls back to full redraw when no scroll happened" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 5)
      frame1 = build_frame_with_window(state1, viewport_top: 5)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      frame2 = build_frame_with_window(state1, viewport_top: 5)
      Emit.emit(frame2, Context.from_editor_state(state1), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    test "scroll_region uses negative delta for scrolling up" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 10)
      frame1 = build_frame_with_window(state1, viewport_top: 10)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 8)
      frame2 = build_frame_with_window(state2, viewport_top: 8)
      Emit.emit(frame2, Context.from_editor_state(state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, scroll_commands}}
      refute match?([<<0x12>> | _], scroll_commands)

      scroll_cmd =
        Enum.find(scroll_commands, fn cmd -> match?(<<0x1B, _::binary>>, cmd) end)

      assert <<0x1B, _top::16, _bottom::16, delta::16-signed>> = scroll_cmd
      assert delta == -2
    end

    test "always includes batch_end in scroll region commands" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert <<0x13>> = List.last(commands)
    end

    test "always includes cursor commands in scroll region output" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert Enum.any?(commands, fn cmd -> match?(<<0x11, _::binary>>, cmd) end)
      assert Enum.any?(commands, fn cmd -> match?(<<0x15, _::binary>>, cmd) end)
    end

    test "falls back to full redraw in visual mode" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      visual_state2 = put_in(state2.workspace.editing.mode, :visual)
      frame2 = build_frame_with_window(visual_state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(visual_state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    test "falls back to full redraw in visual line mode" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      visual_state2 = put_in(state2.workspace.editing.mode, :visual_line)
      frame2 = build_frame_with_window(visual_state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(visual_state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    test "falls back to full redraw in search mode" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      search_state2 = put_in(state2.workspace.editing.mode, :search)
      frame2 = build_frame_with_window(search_state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(search_state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    test "falls back to full redraw when file tree sidebar is visible" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      state1 = seed_state(state, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      state2 = simulate_scroll(state, 1)
      ctx2 = Context.from_editor_state(state2)
      ctx2 = %{ctx2 | layout: %{ctx2.layout | file_tree: {1, 0, 30, 21}}}
      frame2 = build_frame_with_window(state2, viewport_top: 1)
      Emit.emit(frame2, ctx2, nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
    end

    test "falls back to full redraw on mode transition (visual to normal)" do
      state = base_state(rows: 24, cols: 80, content: long_content(100))

      visual_state1 = put_in(state.workspace.editing.mode, :visual)
      state1 = seed_state(visual_state1, 0)
      frame1 = build_frame_with_window(state1, viewport_top: 0)
      {caches, _} = Emit.emit(frame1, Context.from_editor_state(state1), nil)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      normal_state2 = simulate_scroll(put_in(state.workspace.editing.mode, :normal), 1)
      frame2 = build_frame_with_window(normal_state2, viewport_top: 1)
      Emit.emit(frame2, Context.from_editor_state(normal_state2), nil, caches)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [<<0x12>> | _] = commands
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

  @spec set_cached_cursor_line(MingaEditor.State.t(), non_neg_integer()) :: MingaEditor.State.t()
  defp set_cached_cursor_line(state, cursor_line) do
    win_id = state.workspace.windows.active
    window = Map.fetch!(state.workspace.windows.map, win_id)
    render_cache = %{window.render_cache | last_cursor_line: cursor_line}
    window = %{window | render_cache: render_cache}
    put_in(state.workspace.windows.map, Map.put(state.workspace.windows.map, win_id, window))
  end

  @spec render_model_with_rows([String.t()]) :: CoreRenderModel.t()
  defp render_model_with_rows(texts) do
    rows =
      texts
      |> Enum.with_index()
      |> Enum.map(fn {text, index} ->
        %Row{
          row_id: Row.stable_id(:normal, index),
          row_type: :normal,
          buf_line: index,
          text: text,
          spans: [],
          content_hash: :erlang.phash2(text)
        }
      end)

    CoreRenderModel.new(
      [
        %RenderWindow{
          window_id: 1,
          content_kind: :buffer,
          rect: {0, 0, 20, max(length(rows), 1)},
          rows: rows,
          cursor_row: 0,
          cursor_col: 0,
          cursor_shape: :block
        }
      ],
      %Minga.RenderModel.UI{},
      RenderCursor.new(0, 0, :block)
    )
  end

  @spec render_model_with_gutter_and_tilde() :: CoreRenderModel.t()
  defp render_model_with_gutter_and_tilde do
    rows = [
      %Row{
        row_id: Row.stable_id(:normal, 0),
        row_type: :normal,
        buf_line: 0,
        text: "row0",
        spans: [],
        content_hash: 1
      },
      %Row{
        row_id: Row.stable_id(:normal, 1),
        row_type: :normal,
        buf_line: 1,
        text: "row1",
        spans: [],
        content_hash: 2
      }
    ]

    CoreRenderModel.new(
      [
        %RenderWindow{
          window_id: 1,
          content_kind: :buffer,
          rect: {0, 0, 20, 3},
          geometry: %PaneGeometry{
            window_id: 1,
            total_rect: {0, 0, 20, 3},
            content_rect: {0, 0, 20, 3},
            text_rect: {0, 4, 16, 3},
            gutter_rect: {0, 0, 4, 3},
            clip_rect: {0, 4, 16, 3},
            viewport: nil,
            gutter_metrics: nil,
            hit_regions: []
          },
          gutter: %Gutter{
            window_id: 1,
            content_row: 0,
            content_col: 0,
            content_height: 3,
            is_active: true,
            content_width: 20,
            cursor_line: 1,
            line_number_style: :absolute,
            line_number_width: 1,
            sign_col_width: 3,
            entries: [
              %GutterEntry{buf_line: 0, display_type: :normal, sign_type: :none},
              %GutterEntry{buf_line: 1, display_type: :normal, sign_type: :diag_error}
            ]
          },
          rows: rows,
          cursor_row: 0,
          cursor_col: 0,
          cursor_shape: :block
        }
      ],
      %Minga.RenderModel.UI{},
      RenderCursor.new(0, 0, :block)
    )
  end

  @spec decoded_draw_texts([binary()]) :: [String.t()]
  defp decoded_draw_texts(commands) do
    commands
    |> decoded_draws()
    |> Enum.map(& &1.text)
  end

  @spec decoded_draws([binary()]) :: [map()]
  defp decoded_draws(commands) do
    Enum.flat_map(commands, fn command ->
      case Protocol.decode_command(command) do
        {:ok, {:draw_text, draw}} -> [draw]
        {:ok, {:draw_styled_text, draw}} -> [draw]
        _ -> []
      end
    end)
  end
end
