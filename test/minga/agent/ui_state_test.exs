defmodule Minga.Agent.UIStateTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer

  # Creates a UIState with a running prompt buffer containing the given text.
  defp panel_with_input(lines, cursor \\ nil) do
    text = Enum.join(lines, "\n")
    cursor = cursor || {0, 0}
    panel = UIState.new()
    panel = UIState.ensure_prompt_buffer(panel)
    BufferServer.replace_content(panel.prompt_buffer, text)
    BufferServer.set_cursor(panel.prompt_buffer, cursor)
    panel
  end

  # Moves the cursor in the prompt buffer.
  defp set_input_cursor(panel, cursor) do
    BufferServer.set_cursor(panel.prompt_buffer, cursor)
    panel
  end

  describe "new/0" do
    test "starts not visible" do
      panel = UIState.new()
      refute panel.visible
    end

    test "starts with empty input" do
      panel = UIState.new()
      assert UIState.input_text(panel) == ""
    end

    test "starts not focused" do
      panel = UIState.new()
      refute panel.input_focused
    end

    test "starts with empty prompt history" do
      panel = UIState.new()
      assert panel.prompt_history == []
      assert panel.history_index == -1
    end
  end

  describe "toggle/1" do
    test "toggles visibility" do
      panel = UIState.new()
      assert UIState.toggle(panel).visible
      refute panel |> UIState.toggle() |> UIState.toggle() |> Map.get(:visible)
    end
  end

  describe "insert_char/2" do
    test "inserts a character" do
      panel = panel_with_input([""])
      panel = UIState.insert_char(panel, "h")
      assert UIState.input_lines(panel) == ["h"]
    end

    test "appends characters at cursor" do
      panel = panel_with_input([""])
      panel = UIState.insert_char(panel, "h")
      panel = UIState.insert_char(panel, "i")
      assert UIState.input_lines(panel) == ["hi"]
    end

    test "resets history index" do
      panel = panel_with_input([""])
      panel = %{panel | history_index: 2}
      panel = UIState.insert_char(panel, "x")
      assert panel.history_index == -1
    end
  end

  describe "insert_newline/1" do
    test "splits line at cursor" do
      panel = panel_with_input(["hello"], {0, 2})
      panel = UIState.insert_newline(panel)
      assert UIState.input_lines(panel) == ["he", "llo"]
    end

    test "inserts at end of line" do
      panel = panel_with_input(["hi"], {0, 2})
      panel = UIState.insert_newline(panel)
      assert UIState.input_lines(panel) == ["hi", ""]
    end
  end

  describe "delete_char/1" do
    test "deletes character before cursor" do
      panel = panel_with_input(["hi"], {0, 2})
      panel = UIState.delete_char(panel)
      assert UIState.input_lines(panel) == ["h"]
    end

    test "no-op at start of buffer" do
      panel = panel_with_input(["hi"], {0, 0})
      panel = UIState.delete_char(panel)
      assert UIState.input_lines(panel) == ["hi"]
    end

    test "joins lines at start of non-first line" do
      panel = panel_with_input(["ab", "cd"], {1, 0})
      panel = UIState.delete_char(panel)
      assert UIState.input_lines(panel) == ["abcd"]
    end
  end

  describe "move_cursor_up/1" do
    test "returns :at_top on first line" do
      panel = panel_with_input(["hello"], {0, 0})
      assert UIState.move_cursor_up(panel) == :at_top
    end

    test "moves cursor up" do
      panel = panel_with_input(["ab", "cd"], {1, 0})
      result = UIState.move_cursor_up(panel)
      refute result == :at_top
    end
  end

  describe "move_cursor_down/1" do
    test "returns :at_bottom on last line" do
      panel = panel_with_input(["hello"], {0, 0})
      assert UIState.move_cursor_down(panel) == :at_bottom
    end

    test "moves cursor down" do
      panel = panel_with_input(["ab", "cd"], {0, 0})
      result = UIState.move_cursor_down(panel)
      refute result == :at_bottom
    end
  end

  describe "clear_input/1" do
    test "clears to empty" do
      panel = panel_with_input(["hello", "world"])
      panel = UIState.clear_input(panel)
      assert UIState.input_lines(panel) == [""]
      assert UIState.input_text(panel) == ""
    end

    test "saves non-empty text to history" do
      panel = panel_with_input(["hello"])
      panel = UIState.clear_input(panel)
      assert panel.prompt_history == ["hello"]
    end

    test "resets history index" do
      panel = panel_with_input(["hello"])
      panel = %{panel | history_index: 1}
      panel = UIState.clear_input(panel)
      assert panel.history_index == -1
    end

    test "clears pasted_blocks" do
      panel = panel_with_input(["hello"])
      panel = %{panel | pasted_blocks: [%{text: "paste", expanded: false}]}
      panel = UIState.clear_input(panel)
      assert panel.pasted_blocks == []
    end
  end

  describe "input_text/1" do
    test "returns raw buffer content" do
      panel = panel_with_input(["hello", "world"])
      assert UIState.input_text(panel) == "hello\nworld"
    end

    test "returns empty string when no buffer" do
      panel = UIState.new()
      assert UIState.input_text(panel) == ""
    end
  end

  describe "prompt_text/1" do
    test "returns text with placeholders substituted" do
      panel = panel_with_input(["before", "\0PASTE:0", "after"])
      panel = %{panel | pasted_blocks: [%{text: "line1\nline2\nline3", expanded: false}]}
      assert UIState.prompt_text(panel) == "before\nline1\nline2\nline3\nafter"
    end

    test "returns raw text when no placeholders" do
      panel = panel_with_input(["hello"])
      assert UIState.prompt_text(panel) == "hello"
    end
  end

  describe "input_lines/1" do
    test "returns lines from buffer" do
      panel = panel_with_input(["ab", "cd"])
      assert UIState.input_lines(panel) == ["ab", "cd"]
    end

    test "returns empty line when no buffer" do
      panel = UIState.new()
      assert UIState.input_lines(panel) == [""]
    end
  end

  describe "input_cursor/1" do
    test "returns cursor from buffer" do
      panel = panel_with_input(["hello"], {0, 3})
      assert UIState.input_cursor(panel) == {0, 3}
    end

    test "returns {0, 0} when no buffer" do
      panel = UIState.new()
      assert UIState.input_cursor(panel) == {0, 0}
    end
  end

  describe "input_line_count/1" do
    test "returns line count from buffer" do
      panel = panel_with_input(["a", "b", "c"])
      assert UIState.input_line_count(panel) == 3
    end

    test "returns 1 when no buffer" do
      panel = UIState.new()
      assert UIState.input_line_count(panel) == 1
    end
  end

  describe "input_empty?/1" do
    test "true when buffer is empty" do
      panel = panel_with_input([""])
      assert UIState.input_empty?(panel)
    end

    test "false when buffer has content" do
      panel = panel_with_input(["hello"])
      refute UIState.input_empty?(panel)
    end

    test "true when no buffer" do
      panel = UIState.new()
      assert UIState.input_empty?(panel)
    end
  end

  describe "set_input_focused/2" do
    test "focusing starts prompt buffer" do
      panel = UIState.new()
      panel = UIState.set_input_focused(panel, true)
      assert panel.input_focused
      assert is_pid(panel.prompt_buffer)
    end

    test "unfocusing preserves state" do
      panel = panel_with_input(["hello"])
      panel = UIState.set_input_focused(panel, true)
      panel = UIState.set_input_focused(panel, false)
      refute panel.input_focused
      # Buffer and content preserved
      assert UIState.input_lines(panel) == ["hello"]
    end
  end

  describe "history_prev/1" do
    test "no-op with empty history" do
      panel = panel_with_input(["current"])
      assert UIState.history_prev(panel) == panel
    end

    test "recalls previous entry" do
      panel = panel_with_input([""])
      panel = %{panel | prompt_history: ["first", "second"]}
      panel = UIState.history_prev(panel)
      assert UIState.input_text(panel) == "first"
      assert panel.history_index == 0
    end

    test "walks through history" do
      panel = panel_with_input([""])
      panel = %{panel | prompt_history: ["first", "second"]}
      panel = UIState.history_prev(panel)
      panel = UIState.history_prev(panel)
      assert UIState.input_text(panel) == "second"
      assert panel.history_index == 1
    end

    test "clamps at oldest entry" do
      panel = panel_with_input([""])
      panel = %{panel | prompt_history: ["only"]}
      panel = UIState.history_prev(panel)
      panel = UIState.history_prev(panel)
      assert UIState.input_text(panel) == "only"
      assert panel.history_index == 0
    end
  end

  describe "history_next/1" do
    test "no-op at index -1" do
      panel = panel_with_input([""])
      panel = UIState.history_next(panel)
      assert UIState.input_text(panel) == ""
    end

    test "clears input at index 0" do
      panel = panel_with_input([""])
      panel = %{panel | prompt_history: ["entry"], history_index: 0}
      BufferServer.replace_content(panel.prompt_buffer, "entry")
      panel = UIState.history_next(panel)
      assert UIState.input_text(panel) == ""
      assert panel.history_index == -1
    end

    test "recalls more recent entry" do
      panel = panel_with_input([""])
      panel = %{panel | prompt_history: ["first", "second"], history_index: 1}
      panel = UIState.history_next(panel)
      assert UIState.input_text(panel) == "first"
      assert panel.history_index == 0
    end
  end

  describe "save_to_history/1" do
    test "saves non-empty text" do
      panel = panel_with_input(["hello"])
      panel = UIState.save_to_history(panel)
      assert panel.prompt_history == ["hello"]
    end

    test "skips empty text" do
      panel = panel_with_input([""])
      panel = UIState.save_to_history(panel)
      assert panel.prompt_history == []
    end

    test "skips whitespace-only text" do
      panel = panel_with_input(["   "])
      panel = UIState.save_to_history(panel)
      assert panel.prompt_history == []
    end
  end

  describe "insert_paste/2" do
    test "no-op for empty text" do
      panel = panel_with_input([""])
      assert UIState.insert_paste(panel, "") == panel
    end

    test "inserts short paste directly" do
      panel = panel_with_input([""])
      panel = UIState.insert_paste(panel, "hello")
      assert UIState.input_text(panel) == "hello"
    end

    test "inserts two-line paste directly" do
      panel = panel_with_input([""])
      panel = UIState.insert_paste(panel, "line1\nline2")
      assert UIState.input_text(panel) == "line1\nline2"
    end

    test "collapses paste with 3+ lines" do
      panel = panel_with_input([""])
      panel = UIState.insert_paste(panel, "a\nb\nc")
      assert length(panel.pasted_blocks) == 1
      assert hd(panel.pasted_blocks).text == "a\nb\nc"
      # prompt_text expands placeholders
      assert UIState.prompt_text(panel) == "a\nb\nc"
    end

    test "strips NUL bytes from paste" do
      panel = panel_with_input([""])
      panel = UIState.insert_paste(panel, "hello\0world")
      assert UIState.input_text(panel) == "helloworld"
    end

    test "multiple collapsed pastes" do
      panel = panel_with_input([""])
      panel = UIState.insert_paste(panel, "a\nb\nc")
      panel = UIState.insert_paste(panel, "d\ne\nf")
      assert length(panel.pasted_blocks) == 2
    end
  end

  describe "toggle_paste_expand/1" do
    test "expands a collapsed block" do
      panel = panel_with_input([""])
      panel = UIState.insert_paste(panel, "line1\nline2\nline3")
      # Move cursor to the placeholder line
      lines = UIState.input_lines(panel)

      placeholder_idx =
        Enum.find_index(lines, &UIState.paste_placeholder?/1)

      panel = set_input_cursor(panel, {placeholder_idx, 0})
      panel = UIState.toggle_paste_expand(panel)

      block = hd(panel.pasted_blocks)
      assert block.expanded
      assert UIState.input_line_count(panel) >= 3
    end

    test "collapses an expanded block" do
      panel = panel_with_input([""])
      panel = UIState.insert_paste(panel, "line1\nline2\nline3")
      lines = UIState.input_lines(panel)

      placeholder_idx =
        Enum.find_index(lines, &UIState.paste_placeholder?/1)

      panel = set_input_cursor(panel, {placeholder_idx, 0})
      # Expand
      panel = UIState.toggle_paste_expand(panel)
      assert hd(panel.pasted_blocks).expanded

      # Set cursor within expanded text
      panel = set_input_cursor(panel, {placeholder_idx, 0})
      # Collapse
      panel = UIState.toggle_paste_expand(panel)
      refute hd(panel.pasted_blocks).expanded
    end

    test "no-op when cursor not on paste" do
      panel = panel_with_input(["hello"])
      panel2 = UIState.toggle_paste_expand(panel)
      assert UIState.input_lines(panel2) == UIState.input_lines(panel)
    end
  end

  describe "paste_placeholder?/1" do
    test "true for placeholder" do
      assert UIState.paste_placeholder?("\0PASTE:0")
    end

    test "false for regular text" do
      refute UIState.paste_placeholder?("hello")
    end
  end

  describe "paste_block_index/1" do
    test "returns index for placeholder" do
      assert UIState.paste_block_index("\0PASTE:0") == 0
      assert UIState.paste_block_index("\0PASTE:5") == 5
    end

    test "returns nil for non-placeholder" do
      assert UIState.paste_block_index("hello") == nil
    end
  end

  describe "scrolling" do
    test "scroll_up unpins from bottom" do
      panel = UIState.new()
      panel = UIState.scroll_up(panel, 5)
      refute panel.scroll.pinned
    end

    test "scroll_down unpins from bottom" do
      panel = UIState.new()
      # First unpin by scrolling up, then scroll down
      panel = %{panel | scroll: %{panel.scroll | offset: 10, pinned: false}}
      panel = UIState.scroll_down(panel, 3)
      assert panel.scroll.offset == 13
    end
  end

  describe "clear_display/2" do
    test "sets display_start_index and resets scroll" do
      panel = UIState.new()
      panel = UIState.scroll_up(panel, 10)
      panel = UIState.clear_display(panel, 5)
      assert panel.display_start_index == 5
      assert panel.scroll.offset == 0
    end
  end

  describe "ensure_prompt_buffer/1" do
    test "starts buffer when nil" do
      panel = UIState.new()
      panel = UIState.ensure_prompt_buffer(panel)
      assert is_pid(panel.prompt_buffer)
      assert Process.alive?(panel.prompt_buffer)
    end

    test "idempotent when alive" do
      panel = UIState.new()
      panel = UIState.ensure_prompt_buffer(panel)
      pid = panel.prompt_buffer
      panel = UIState.ensure_prompt_buffer(panel)
      assert panel.prompt_buffer == pid
    end

    test "restarts when dead" do
      Process.flag(:trap_exit, true)
      panel = UIState.new()
      panel = UIState.ensure_prompt_buffer(panel)
      old_pid = panel.prompt_buffer
      Process.exit(old_pid, :kill)

      receive do
        {:EXIT, ^old_pid, :killed} -> :ok
      after
        100 -> flunk("expected EXIT")
      end

      panel = UIState.ensure_prompt_buffer(panel)
      assert is_pid(panel.prompt_buffer)
      assert panel.prompt_buffer != old_pid
    end
  end
end
