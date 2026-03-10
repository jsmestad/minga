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

    test "scroll_to_bottom engages auto_scroll without changing offset" do
      panel = PanelState.new() |> PanelState.scroll_down(10) |> PanelState.scroll_to_bottom()
      assert panel.auto_scroll
      # offset stays at what scroll_down set; renderer resolves "bottom"
      assert panel.scroll_offset == 10
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

    test "maybe_auto_scroll is always a no-op (renderer handles pinning)" do
      panel = PanelState.new() |> PanelState.maybe_auto_scroll()
      # auto_scroll stays true (default), offset untouched
      assert panel.scroll_offset == 0
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

    test "engage_auto_scroll re-engages auto_scroll flag" do
      panel =
        PanelState.new()
        |> PanelState.scroll_up(5)
        |> PanelState.engage_auto_scroll()

      assert panel.auto_scroll
      # offset is not reset to a sentinel; renderer handles bottom pinning
      assert panel.scroll_offset == 0
    end

    test "scroll_down from auto_scroll produces concrete offset, not sentinel" do
      # This is the core regression test. Previously scroll_to_bottom set
      # scroll_offset to 999_999. scroll_down(1) would produce 1_000_000,
      # and the renderer's clamp made both resolve to the same visible
      # content. With the two-field model, scroll_offset stays concrete.
      panel =
        PanelState.new()
        |> PanelState.scroll_down(5)

      assert panel.scroll_offset == 5
      refute panel.auto_scroll
    end

    test "scroll_up from auto_scroll produces concrete offset, not sentinel" do
      # Previously: scroll_offset was 999_999, scroll_up(1) => 999_998,
      # both clamped to the same value by the renderer. Now: offset starts
      # at 0, scroll_up(1) => 0 (clamped), which is different from bottom.
      panel =
        PanelState.new()
        |> PanelState.scroll_up(1)

      assert panel.scroll_offset == 0
      refute panel.auto_scroll
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

  # ── Paste handling ─────────────────────────────────────────────────────────

  describe "insert_paste/2 — short pastes (below collapse threshold)" do
    test "empty paste is a no-op" do
      panel = PanelState.new()
      result = PanelState.insert_paste(panel, "")
      assert result == panel
    end

    test "single-line paste inserts inline" do
      panel = PanelState.new()
      result = PanelState.insert_paste(panel, "hello world")
      assert result.input_lines == ["hello world"]
      assert result.input_cursor == {0, 11}
      assert result.pasted_blocks == []
    end

    test "two-line paste inserts inline as two lines" do
      panel = PanelState.new()
      result = PanelState.insert_paste(panel, "line 1\nline 2")
      assert result.input_lines == ["line 1", "line 2"]
      assert result.input_cursor == {1, 6}
      assert result.pasted_blocks == []
    end

    test "single-line paste into existing text at cursor" do
      panel = PanelState.new()
      panel = PanelState.insert_char(panel, "h")
      panel = PanelState.insert_char(panel, "i")
      # cursor at {0, 2}, line is "hi"
      result = PanelState.insert_paste(panel, " there")
      assert result.input_lines == ["hi there"]
      assert result.input_cursor == {0, 8}
    end

    test "two-line paste into middle of existing text" do
      panel = %{PanelState.new() | input_lines: ["abcdef"], input_cursor: {0, 3}}
      result = PanelState.insert_paste(panel, "X\nY")
      assert result.input_lines == ["abcX", "Ydef"]
      assert result.input_cursor == {1, 1}
    end

    test "two-line paste at start of existing text" do
      panel = %{PanelState.new() | input_lines: ["hello"], input_cursor: {0, 0}}
      result = PanelState.insert_paste(panel, "A\nB")
      assert result.input_lines == ["A", "Bhello"]
      assert result.input_cursor == {1, 1}
    end

    test "two-line paste at end of existing text" do
      panel = %{PanelState.new() | input_lines: ["hello"], input_cursor: {0, 5}}
      result = PanelState.insert_paste(panel, "A\nB")
      assert result.input_lines == ["helloA", "B"]
      assert result.input_cursor == {1, 1}
    end
  end

  describe "insert_paste/2 — long pastes (at or above collapse threshold)" do
    test "3-line paste creates a collapsed block" do
      panel = PanelState.new()
      text = "line 1\nline 2\nline 3"
      result = PanelState.insert_paste(panel, text)

      assert length(result.pasted_blocks) == 1
      assert hd(result.pasted_blocks).text == text
      assert hd(result.pasted_blocks).expanded == false

      # Input should contain the placeholder
      assert Enum.any?(result.input_lines, &PanelState.paste_placeholder?/1)
    end

    test "input_text/1 substitutes placeholder with full paste content" do
      panel = PanelState.new()
      text = "line 1\nline 2\nline 3"
      result = PanelState.insert_paste(panel, text)

      assert PanelState.input_text(result) == text
    end

    test "5-line paste into empty input" do
      panel = PanelState.new()
      text = "a\nb\nc\nd\ne"
      result = PanelState.insert_paste(panel, text)

      assert length(result.pasted_blocks) == 1
      assert hd(result.pasted_blocks).text == text
      assert PanelState.input_text(result) == text
    end

    test "paste into existing text preserves surrounding content" do
      panel = %{PanelState.new() | input_lines: ["question: "], input_cursor: {0, 10}}
      text = "line 1\nline 2\nline 3"
      result = PanelState.insert_paste(panel, text)

      full_text = PanelState.input_text(result)
      assert String.starts_with?(full_text, "question: ")
      assert String.contains?(full_text, text)
    end

    test "paste into middle of existing text splits around placeholder" do
      panel = %{PanelState.new() | input_lines: ["abcdef"], input_cursor: {0, 3}}
      text = "X\nY\nZ"
      result = PanelState.insert_paste(panel, text)

      full_text = PanelState.input_text(result)
      assert full_text == "abc\nX\nY\nZ\ndef"
    end

    test "paste at start of line with existing content" do
      panel = %{PanelState.new() | input_lines: ["existing"], input_cursor: {0, 0}}
      text = "a\nb\nc"
      result = PanelState.insert_paste(panel, text)

      full_text = PanelState.input_text(result)
      # Placeholder is its own line; "existing" stays after
      assert String.ends_with?(full_text, "\nexisting")
    end

    test "paste at end of existing line" do
      panel = %{PanelState.new() | input_lines: ["existing"], input_cursor: {0, 8}}
      text = "a\nb\nc"
      result = PanelState.insert_paste(panel, text)

      full_text = PanelState.input_text(result)
      assert String.starts_with?(full_text, "existing\n")
    end

    test "multiple pastes accumulate separate blocks" do
      panel = PanelState.new()
      text1 = "a\nb\nc"
      text2 = "d\ne\nf"

      result =
        panel
        |> PanelState.insert_paste(text1)
        |> PanelState.insert_paste(text2)

      assert length(result.pasted_blocks) == 2
      assert Enum.at(result.pasted_blocks, 0).text == text1
      assert Enum.at(result.pasted_blocks, 1).text == text2

      full_text = PanelState.input_text(result)
      assert String.contains?(full_text, text1)
      assert String.contains?(full_text, text2)
    end

    test "unicode paste content is preserved" do
      panel = PanelState.new()
      text = "こんにちは\n🎉 emoji\n中文テスト"
      result = PanelState.insert_paste(panel, text)

      assert PanelState.input_text(result) == text
    end

    test "paste with trailing newline" do
      panel = PanelState.new()
      text = "line 1\nline 2\nline 3\n"
      result = PanelState.insert_paste(panel, text)

      assert PanelState.input_text(result) == text
    end

    test "paste with only newlines" do
      panel = PanelState.new()
      text = "\n\n\n"
      result = PanelState.insert_paste(panel, text)

      # 4 lines (split on \n gives ["", "", "", ""])
      assert length(result.pasted_blocks) == 1
      assert PanelState.input_text(result) == text
    end

    test "NUL bytes in pasted text are stripped to prevent placeholder injection" do
      panel = PanelState.new()
      # Try to inject a fake placeholder
      text = "\0PASTE:99\nline 2\nline 3"
      result = PanelState.insert_paste(panel, text)

      # The NUL should be stripped, so it's treated as a regular 3-line paste
      assert hd(result.pasted_blocks).text == "PASTE:99\nline 2\nline 3"
    end
  end

  describe "toggle_paste_expand/1" do
    test "expands a collapsed paste block" do
      panel = PanelState.new()
      text = "line 1\nline 2\nline 3"
      panel = PanelState.insert_paste(panel, text)

      # Find the placeholder line
      placeholder_idx = Enum.find_index(panel.input_lines, &PanelState.paste_placeholder?/1)
      panel = %{panel | input_cursor: {placeholder_idx, 0}}

      expanded = PanelState.toggle_paste_expand(panel)

      # After expanding, pasted_blocks[0].expanded should be true
      assert Enum.at(expanded.pasted_blocks, 0).expanded == true

      # The placeholder should be replaced with actual text lines
      refute Enum.any?(expanded.input_lines, &PanelState.paste_placeholder?/1)
      assert "line 1" in expanded.input_lines
      assert "line 2" in expanded.input_lines
      assert "line 3" in expanded.input_lines
    end

    test "collapses an expanded paste block" do
      panel = PanelState.new()
      text = "line 1\nline 2\nline 3"
      panel = PanelState.insert_paste(panel, text)

      # Expand it first
      placeholder_idx = Enum.find_index(panel.input_lines, &PanelState.paste_placeholder?/1)
      panel = %{panel | input_cursor: {placeholder_idx, 0}}
      panel = PanelState.toggle_paste_expand(panel)

      # Now collapse: put cursor on the first line of the expanded text
      panel = %{panel | input_cursor: {placeholder_idx, 0}}
      collapsed = PanelState.toggle_paste_expand(panel)

      # After collapsing, should have placeholder back
      assert Enum.any?(collapsed.input_lines, &PanelState.paste_placeholder?/1)
      assert Enum.at(collapsed.pasted_blocks, 0).expanded == false
    end

    test "no-op when cursor is not on a placeholder line" do
      panel = PanelState.new()
      panel = %{panel | input_lines: ["regular text"], input_cursor: {0, 0}}
      result = PanelState.toggle_paste_expand(panel)
      assert result == panel
    end

    test "input_text returns same content whether expanded or collapsed" do
      panel = PanelState.new()
      text = "alpha\nbeta\ngamma"
      panel = PanelState.insert_paste(panel, text)
      collapsed_text = PanelState.input_text(panel)

      # Expand
      placeholder_idx = Enum.find_index(panel.input_lines, &PanelState.paste_placeholder?/1)

      expanded_panel =
        %{panel | input_cursor: {placeholder_idx, 0}} |> PanelState.toggle_paste_expand()

      expanded_text = PanelState.input_text(expanded_panel)

      assert collapsed_text == expanded_text
    end
  end

  describe "paste_placeholder?/1" do
    test "detects placeholder lines" do
      assert PanelState.paste_placeholder?("\0PASTE:0")
      assert PanelState.paste_placeholder?("\0PASTE:42")
    end

    test "rejects normal text" do
      refute PanelState.paste_placeholder?("normal text")
      refute PanelState.paste_placeholder?("")
      refute PanelState.paste_placeholder?("PASTE:0")
    end
  end

  describe "paste_block_index/1" do
    test "extracts index from placeholder" do
      assert PanelState.paste_block_index("\0PASTE:0") == 0
      assert PanelState.paste_block_index("\0PASTE:5") == 5
      assert PanelState.paste_block_index("\0PASTE:123") == 123
    end

    test "returns nil for non-placeholder" do
      assert PanelState.paste_block_index("regular text") == nil
      assert PanelState.paste_block_index("") == nil
    end
  end

  describe "paste_block_line_count/2" do
    test "returns line count for a paste block" do
      panel = PanelState.new()
      panel = PanelState.insert_paste(panel, "a\nb\nc\nd\ne")
      assert PanelState.paste_block_line_count(panel, 0) == 5
    end

    test "returns 0 for invalid index" do
      panel = PanelState.new()
      assert PanelState.paste_block_line_count(panel, 99) == 0
    end
  end

  describe "clear_input/1 with pasted blocks" do
    test "clears pasted_blocks along with input" do
      panel = PanelState.new()
      panel = PanelState.insert_paste(panel, "a\nb\nc")

      assert length(panel.pasted_blocks) == 1

      cleared = PanelState.clear_input(panel)
      assert cleared.pasted_blocks == []
      assert cleared.input_lines == [""]
      assert cleared.input_cursor == {0, 0}
    end
  end

  describe "new/0 with pasted_blocks" do
    test "starts with empty pasted_blocks" do
      panel = PanelState.new()
      assert panel.pasted_blocks == []
    end
  end
end
