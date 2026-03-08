defmodule Minga.Agent.PanelStateTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState

  describe "new/0" do
    test "starts not visible" do
      panel = PanelState.new()
      refute panel.visible
    end

    test "starts with empty input" do
      panel = PanelState.new()
      assert panel.input_lines == [""]
      assert panel.input_cursor == {0, 0}
      assert PanelState.input_text(panel) == ""
    end

    test "starts at scroll offset 0" do
      panel = PanelState.new()
      assert panel.scroll_offset == 0
    end

    test "starts with empty prompt history" do
      panel = PanelState.new()
      assert panel.prompt_history == []
      assert panel.history_index == -1
    end
  end

  describe "toggle/1" do
    test "toggles visibility on" do
      panel = PanelState.new() |> PanelState.toggle()
      assert panel.visible
    end

    test "toggles visibility off" do
      panel = PanelState.new() |> PanelState.toggle() |> PanelState.toggle()
      refute panel.visible
    end
  end

  describe "input_text/1" do
    test "joins multiple lines with newlines" do
      panel = %{PanelState.new() | input_lines: ["hello", "world"]}
      assert PanelState.input_text(panel) == "hello\nworld"
    end

    test "returns empty string for empty input" do
      panel = PanelState.new()
      assert PanelState.input_text(panel) == ""
    end
  end

  describe "insert_char/2" do
    test "inserts character at cursor position" do
      panel = PanelState.new() |> PanelState.insert_char("h") |> PanelState.insert_char("i")
      assert PanelState.input_text(panel) == "hi"
      assert panel.input_cursor == {0, 2}
    end

    test "inserts in the middle of text" do
      panel = %{PanelState.new() | input_lines: ["hlo"], input_cursor: {0, 1}}
      panel = PanelState.insert_char(panel, "el")
      assert panel.input_lines == ["hello"]
      assert panel.input_cursor == {0, 3}
    end

    test "resets history index on edit" do
      panel = %{PanelState.new() | history_index: 2}
      panel = PanelState.insert_char(panel, "a")
      assert panel.history_index == -1
    end
  end

  describe "insert_newline/1" do
    test "splits line at cursor" do
      panel = %{PanelState.new() | input_lines: ["hello world"], input_cursor: {0, 5}}
      panel = PanelState.insert_newline(panel)
      assert panel.input_lines == ["hello", " world"]
      assert panel.input_cursor == {1, 0}
    end

    test "inserts at end of line" do
      panel = %{PanelState.new() | input_lines: ["hello"], input_cursor: {0, 5}}
      panel = PanelState.insert_newline(panel)
      assert panel.input_lines == ["hello", ""]
      assert panel.input_cursor == {1, 0}
    end

    test "inserts at start of line" do
      panel = %{PanelState.new() | input_lines: ["hello"], input_cursor: {0, 0}}
      panel = PanelState.insert_newline(panel)
      assert panel.input_lines == ["", "hello"]
      assert panel.input_cursor == {1, 0}
    end
  end

  describe "delete_char/1" do
    test "deletes character before cursor" do
      panel =
        PanelState.new()
        |> PanelState.insert_char("h")
        |> PanelState.insert_char("i")
        |> PanelState.delete_char()

      assert PanelState.input_text(panel) == "h"
      assert panel.input_cursor == {0, 1}
    end

    test "no-op at start of first line" do
      panel = PanelState.new() |> PanelState.delete_char()
      assert PanelState.input_text(panel) == ""
      assert panel.input_cursor == {0, 0}
    end

    test "joins with previous line when at start of non-first line" do
      panel = %{PanelState.new() | input_lines: ["hello", "world"], input_cursor: {1, 0}}
      panel = PanelState.delete_char(panel)
      assert panel.input_lines == ["helloworld"]
      assert panel.input_cursor == {0, 5}
    end

    test "deletes in middle of text" do
      panel = %{PanelState.new() | input_lines: ["abc"], input_cursor: {0, 2}}
      panel = PanelState.delete_char(panel)
      assert panel.input_lines == ["ac"]
      assert panel.input_cursor == {0, 1}
    end
  end

  describe "clear_input/1" do
    test "empties the input and resets cursor" do
      panel =
        PanelState.new()
        |> PanelState.insert_char("test")
        |> PanelState.clear_input()

      assert panel.input_lines == [""]
      assert panel.input_cursor == {0, 0}
    end

    test "saves to history before clearing" do
      panel =
        PanelState.new()
        |> PanelState.insert_char("hello")
        |> PanelState.clear_input()

      assert panel.prompt_history == ["hello"]
    end

    test "does not save empty input to history" do
      panel = PanelState.new() |> PanelState.clear_input()
      assert panel.prompt_history == []
    end
  end

  describe "cursor movement" do
    test "move_cursor_up returns :at_top when on first line" do
      panel = PanelState.new()
      assert PanelState.move_cursor_up(panel) == :at_top
    end

    test "move_cursor_up moves to previous line" do
      panel = %{PanelState.new() | input_lines: ["ab", "cd"], input_cursor: {1, 1}}
      panel = PanelState.move_cursor_up(panel)
      assert panel.input_cursor == {0, 1}
    end

    test "move_cursor_up clamps column to shorter line" do
      panel = %{PanelState.new() | input_lines: ["ab", "cdef"], input_cursor: {1, 3}}
      panel = PanelState.move_cursor_up(panel)
      assert panel.input_cursor == {0, 2}
    end

    test "move_cursor_down returns :at_bottom when on last line" do
      panel = PanelState.new()
      assert PanelState.move_cursor_down(panel) == :at_bottom
    end

    test "move_cursor_down moves to next line" do
      panel = %{PanelState.new() | input_lines: ["ab", "cd"], input_cursor: {0, 1}}
      panel = PanelState.move_cursor_down(panel)
      assert panel.input_cursor == {1, 1}
    end

    test "move_cursor_down clamps column to shorter line" do
      panel = %{PanelState.new() | input_lines: ["abcd", "ef"], input_cursor: {0, 3}}
      panel = PanelState.move_cursor_down(panel)
      assert panel.input_cursor == {1, 2}
    end
  end

  describe "prompt history" do
    test "history_prev recalls previous prompt" do
      panel = %{PanelState.new() | prompt_history: ["hello", "world"]}
      panel = PanelState.history_prev(panel)
      assert PanelState.input_text(panel) == "hello"
      assert panel.history_index == 0
    end

    test "history_prev moves through history" do
      panel = %{PanelState.new() | prompt_history: ["hello", "world"]}
      panel = panel |> PanelState.history_prev() |> PanelState.history_prev()
      assert PanelState.input_text(panel) == "world"
      assert panel.history_index == 1
    end

    test "history_prev stops at oldest entry" do
      panel = %{PanelState.new() | prompt_history: ["only"]}
      panel = panel |> PanelState.history_prev() |> PanelState.history_prev()
      assert PanelState.input_text(panel) == "only"
      assert panel.history_index == 0
    end

    test "history_prev is no-op with empty history" do
      panel = PanelState.new() |> PanelState.history_prev()
      assert PanelState.input_text(panel) == ""
    end

    test "history_next moves forward through history" do
      panel = %{PanelState.new() | prompt_history: ["hello", "world"]}
      panel = panel |> PanelState.history_prev() |> PanelState.history_prev()
      panel = PanelState.history_next(panel)
      assert PanelState.input_text(panel) == "hello"
      assert panel.history_index == 0
    end

    test "history_next returns to empty input when past newest" do
      panel = %{PanelState.new() | prompt_history: ["hello"]}
      panel = panel |> PanelState.history_prev() |> PanelState.history_next()
      assert PanelState.input_text(panel) == ""
      assert panel.history_index == -1
    end

    test "history_next is no-op when not browsing history" do
      panel = PanelState.new() |> PanelState.history_next()
      assert PanelState.input_text(panel) == ""
    end

    test "history preserves multi-line prompts" do
      panel = %{PanelState.new() | prompt_history: ["line1\nline2"]}
      panel = PanelState.history_prev(panel)
      assert panel.input_lines == ["line1", "line2"]
      assert panel.input_cursor == {1, 5}
    end

    test "save_to_history adds text to history" do
      panel = %{PanelState.new() | input_lines: ["hello"]}
      panel = PanelState.save_to_history(panel)
      assert panel.prompt_history == ["hello"]
    end

    test "save_to_history does not add empty or whitespace-only text" do
      panel = PanelState.new() |> PanelState.save_to_history()
      assert panel.prompt_history == []

      panel2 = %{PanelState.new() | input_lines: ["  "]}
      panel2 = PanelState.save_to_history(panel2)
      assert panel2.prompt_history == []
    end
  end

  describe "input_line_count/1" do
    test "returns 1 for empty input" do
      assert PanelState.input_line_count(PanelState.new()) == 1
    end

    test "returns count for multi-line input" do
      panel = %{PanelState.new() | input_lines: ["a", "b", "c"]}
      assert PanelState.input_line_count(panel) == 3
    end
  end

  describe "scrolling" do
    test "scroll_down increases offset" do
      panel = PanelState.new() |> PanelState.scroll_down(10)
      assert panel.scroll_offset == 10
    end

    test "scroll_up decreases offset" do
      panel = PanelState.new() |> PanelState.scroll_down(10) |> PanelState.scroll_up(5)
      assert panel.scroll_offset == 5
    end

    test "scroll_up does not go below 0" do
      panel = PanelState.new() |> PanelState.scroll_up(10)
      assert panel.scroll_offset == 0
    end

    test "scroll_to_bottom sets large offset" do
      panel = PanelState.new() |> PanelState.scroll_to_bottom()
      assert panel.scroll_offset > 0
    end
  end

  describe "auto-scroll" do
    test "starts engaged" do
      panel = PanelState.new()
      assert panel.auto_scroll
    end

    test "scroll_up disengages auto-scroll" do
      panel = PanelState.new() |> PanelState.scroll_up(5)
      refute panel.auto_scroll
    end

    test "scroll_down disengages auto-scroll" do
      panel = PanelState.new() |> PanelState.scroll_down(5)
      refute panel.auto_scroll
    end

    test "scroll_to_top disengages auto-scroll" do
      panel = PanelState.new() |> PanelState.scroll_to_top()
      refute panel.auto_scroll
    end

    test "scroll_to_bottom re-engages auto-scroll" do
      panel =
        PanelState.new()
        |> PanelState.scroll_up(5)
        |> PanelState.scroll_to_bottom()

      assert panel.auto_scroll
    end

    test "maybe_auto_scroll scrolls to bottom when engaged" do
      panel = PanelState.new() |> PanelState.maybe_auto_scroll()
      assert panel.scroll_offset == 999_999
      assert panel.auto_scroll
    end

    test "maybe_auto_scroll is a no-op when disengaged" do
      panel =
        PanelState.new()
        |> PanelState.scroll_down(50)
        |> PanelState.maybe_auto_scroll()

      assert panel.scroll_offset == 50
      refute panel.auto_scroll
    end

    test "engage_auto_scroll re-engages and scrolls to bottom" do
      panel =
        PanelState.new()
        |> PanelState.scroll_up(5)
        |> PanelState.engage_auto_scroll()

      assert panel.auto_scroll
      assert panel.scroll_offset == 999_999
    end
  end

  describe "display clear" do
    test "clear_display sets display_start_index" do
      panel = PanelState.new() |> PanelState.clear_display(5)
      assert panel.display_start_index == 5
    end

    test "clear_display resets scroll and re-engages auto-scroll" do
      panel =
        PanelState.new()
        |> PanelState.scroll_down(50)
        |> PanelState.clear_display(3)

      assert panel.scroll_offset == 0
      assert panel.auto_scroll
    end

    test "starts with display_start_index of 0" do
      panel = PanelState.new()
      assert panel.display_start_index == 0
    end
  end

  describe "spinner" do
    test "tick_spinner increments frame" do
      panel = PanelState.new() |> PanelState.tick_spinner() |> PanelState.tick_spinner()
      assert panel.spinner_frame == 2
    end
  end

  describe "input focus" do
    test "set_input_focused changes focus state" do
      panel = PanelState.new() |> PanelState.set_input_focused(true)
      assert panel.input_focused
    end
  end
end
