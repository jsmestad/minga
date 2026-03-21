defmodule Minga.Agent.UIStateTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Config, as: AgentConfig
  alias Minga.Agent.UIState
  alias Minga.Agent.UIState.Panel
  alias Minga.Buffer.Server, as: BufferServer

  # Creates a UIState with a running prompt buffer containing the given text.
  defp ui_with_input(lines, cursor \\ nil) do
    text = Enum.join(lines, "\n")
    cursor = cursor || {0, 0}
    ui = UIState.new()
    ui = UIState.ensure_prompt_buffer(ui)
    BufferServer.replace_content(ui.panel.prompt_buffer, text)
    BufferServer.set_cursor(ui.panel.prompt_buffer, cursor)
    ui
  end

  # Moves the cursor in the prompt buffer.
  defp set_input_cursor(ui, cursor) do
    BufferServer.set_cursor(ui.panel.prompt_buffer, cursor)
    ui
  end

  describe "new/0" do
    test "starts not visible" do
      ui = UIState.new()
      refute ui.panel.visible
    end

    test "starts with empty input" do
      ui = UIState.new()
      assert UIState.input_text(ui) == ""
    end

    test "starts not focused" do
      ui = UIState.new()
      refute ui.panel.input_focused
    end

    test "starts with empty prompt history" do
      ui = UIState.new()
      assert ui.panel.prompt_history == []
      assert ui.panel.history_index == -1
    end

    test "default model_name includes provider prefix" do
      ui = UIState.new()
      assert String.contains?(ui.panel.model_name, ":")
      assert ui.panel.model_name == AgentConfig.default_model()
    end
  end

  describe "toggle/1" do
    test "toggles visibility" do
      ui = UIState.new()
      assert UIState.toggle(ui).panel.visible
      refute ui |> UIState.toggle() |> UIState.toggle() |> then(& &1.panel.visible)
    end
  end

  describe "insert_char/2" do
    test "inserts a character" do
      ui = ui_with_input([""])
      ui = UIState.insert_char(ui, "h")
      assert UIState.input_lines(ui) == ["h"]
    end

    test "appends characters at cursor" do
      ui = ui_with_input([""])
      ui = UIState.insert_char(ui, "h")
      ui = UIState.insert_char(ui, "i")
      assert UIState.input_lines(ui) == ["hi"]
    end

    test "resets history index" do
      ui = ui_with_input([""])
      ui = put_in(ui.panel.history_index, 2)
      ui = UIState.insert_char(ui, "x")
      assert ui.panel.history_index == -1
    end
  end

  describe "insert_newline/1" do
    test "splits line at cursor" do
      ui = ui_with_input(["hello"], {0, 2})
      ui = UIState.insert_newline(ui)
      assert UIState.input_lines(ui) == ["he", "llo"]
    end

    test "inserts at end of line" do
      ui = ui_with_input(["hi"], {0, 2})
      ui = UIState.insert_newline(ui)
      assert UIState.input_lines(ui) == ["hi", ""]
    end
  end

  describe "delete_char/1" do
    test "deletes character before cursor" do
      ui = ui_with_input(["hi"], {0, 2})
      ui = UIState.delete_char(ui)
      assert UIState.input_lines(ui) == ["h"]
    end

    test "no-op at start of buffer" do
      ui = ui_with_input(["hi"], {0, 0})
      ui = UIState.delete_char(ui)
      assert UIState.input_lines(ui) == ["hi"]
    end

    test "joins lines at start of non-first line" do
      ui = ui_with_input(["ab", "cd"], {1, 0})
      ui = UIState.delete_char(ui)
      assert UIState.input_lines(ui) == ["abcd"]
    end
  end

  describe "move_cursor_up/1" do
    test "returns :at_top on first line" do
      ui = ui_with_input(["hello"], {0, 0})
      assert UIState.move_cursor_up(ui) == :at_top
    end

    test "moves cursor up" do
      ui = ui_with_input(["ab", "cd"], {1, 0})
      result = UIState.move_cursor_up(ui)
      refute result == :at_top
    end
  end

  describe "move_cursor_down/1" do
    test "returns :at_bottom on last line" do
      ui = ui_with_input(["hello"], {0, 0})
      assert UIState.move_cursor_down(ui) == :at_bottom
    end

    test "moves cursor down" do
      ui = ui_with_input(["ab", "cd"], {0, 0})
      result = UIState.move_cursor_down(ui)
      refute result == :at_bottom
    end
  end

  describe "clear_input/1" do
    test "clears to empty" do
      ui = ui_with_input(["hello", "world"])
      ui = UIState.clear_input(ui)
      assert UIState.input_lines(ui) == [""]
      assert UIState.input_text(ui) == ""
    end

    test "saves non-empty text to history" do
      ui = ui_with_input(["hello"])
      ui = UIState.clear_input(ui)
      assert ui.panel.prompt_history == ["hello"]
    end

    test "resets history index" do
      ui = ui_with_input(["hello"])
      ui = put_in(ui.panel.history_index, 1)
      ui = UIState.clear_input(ui)
      assert ui.panel.history_index == -1
    end

    test "clears pasted_blocks" do
      ui = ui_with_input(["hello"])
      ui = put_in(ui.panel.pasted_blocks, [%{text: "paste", expanded: false}])
      ui = UIState.clear_input(ui)
      assert ui.panel.pasted_blocks == []
    end
  end

  describe "input_text/1" do
    test "returns raw buffer content" do
      ui = ui_with_input(["hello", "world"])
      assert UIState.input_text(ui) == "hello\nworld"
    end

    test "returns empty string when no buffer" do
      ui = UIState.new()
      assert UIState.input_text(ui) == ""
    end
  end

  describe "prompt_text/1" do
    test "returns text with placeholders substituted" do
      ui = ui_with_input(["before", "\0PASTE:0", "after"])
      ui = put_in(ui.panel.pasted_blocks, [%{text: "line1\nline2\nline3", expanded: false}])
      assert UIState.prompt_text(ui) == "before\nline1\nline2\nline3\nafter"
    end

    test "returns raw text when no placeholders" do
      ui = ui_with_input(["hello"])
      assert UIState.prompt_text(ui) == "hello"
    end
  end

  describe "input_lines/1" do
    test "returns lines from buffer" do
      ui = ui_with_input(["ab", "cd"])
      assert UIState.input_lines(ui) == ["ab", "cd"]
    end

    test "returns empty line when no buffer" do
      ui = UIState.new()
      assert UIState.input_lines(ui) == [""]
    end
  end

  describe "input_cursor/1" do
    test "returns cursor from buffer" do
      ui = ui_with_input(["hello"], {0, 3})
      assert UIState.input_cursor(ui) == {0, 3}
    end

    test "returns {0, 0} when no buffer" do
      ui = UIState.new()
      assert UIState.input_cursor(ui) == {0, 0}
    end
  end

  describe "input_line_count/1" do
    test "returns line count from buffer" do
      ui = ui_with_input(["a", "b", "c"])
      assert UIState.input_line_count(ui) == 3
    end

    test "returns 1 when no buffer" do
      ui = UIState.new()
      assert UIState.input_line_count(ui) == 1
    end
  end

  describe "input_empty?/1" do
    test "true when buffer is empty" do
      ui = ui_with_input([""])
      assert UIState.input_empty?(ui)
    end

    test "false when buffer has content" do
      ui = ui_with_input(["hello"])
      refute UIState.input_empty?(ui)
    end

    test "true when no buffer" do
      ui = UIState.new()
      assert UIState.input_empty?(ui)
    end
  end

  describe "set_input_focused/2" do
    test "focusing starts prompt buffer" do
      ui = UIState.new()
      ui = UIState.set_input_focused(ui, true)
      assert ui.panel.input_focused
      assert is_pid(ui.panel.prompt_buffer)
    end

    test "unfocusing preserves state" do
      ui = ui_with_input(["hello"])
      ui = UIState.set_input_focused(ui, true)
      ui = UIState.set_input_focused(ui, false)
      refute ui.panel.input_focused
      # Buffer and content preserved
      assert UIState.input_lines(ui) == ["hello"]
    end
  end

  describe "history_prev/1" do
    test "no-op with empty history" do
      ui = ui_with_input(["current"])
      assert UIState.history_prev(ui) == ui
    end

    test "recalls previous entry" do
      ui = ui_with_input([""])
      ui = put_in(ui.panel.prompt_history, ["first", "second"])
      ui = UIState.history_prev(ui)
      assert UIState.input_text(ui) == "first"
      assert ui.panel.history_index == 0
    end

    test "walks through history" do
      ui = ui_with_input([""])
      ui = put_in(ui.panel.prompt_history, ["first", "second"])
      ui = UIState.history_prev(ui)
      ui = UIState.history_prev(ui)
      assert UIState.input_text(ui) == "second"
      assert ui.panel.history_index == 1
    end

    test "clamps at oldest entry" do
      ui = ui_with_input([""])
      ui = put_in(ui.panel.prompt_history, ["only"])
      ui = UIState.history_prev(ui)
      ui = UIState.history_prev(ui)
      assert UIState.input_text(ui) == "only"
      assert ui.panel.history_index == 0
    end
  end

  describe "history_next/1" do
    test "no-op at index -1" do
      ui = ui_with_input([""])
      ui = UIState.history_next(ui)
      assert UIState.input_text(ui) == ""
    end

    test "clears input at index 0" do
      ui = ui_with_input([""])
      ui = put_in(ui.panel.prompt_history, ["entry"])
      ui = put_in(ui.panel.history_index, 0)
      BufferServer.replace_content(ui.panel.prompt_buffer, "entry")
      ui = UIState.history_next(ui)
      assert UIState.input_text(ui) == ""
      assert ui.panel.history_index == -1
    end

    test "recalls more recent entry" do
      ui = ui_with_input([""])
      ui = put_in(ui.panel.prompt_history, ["first", "second"])
      ui = put_in(ui.panel.history_index, 1)
      ui = UIState.history_next(ui)
      assert UIState.input_text(ui) == "first"
      assert ui.panel.history_index == 0
    end
  end

  describe "save_to_history/1" do
    test "saves non-empty text" do
      ui = ui_with_input(["hello"])
      ui = UIState.save_to_history(ui)
      assert ui.panel.prompt_history == ["hello"]
    end

    test "skips empty text" do
      ui = ui_with_input([""])
      ui = UIState.save_to_history(ui)
      assert ui.panel.prompt_history == []
    end

    test "skips whitespace-only text" do
      ui = ui_with_input(["   "])
      ui = UIState.save_to_history(ui)
      assert ui.panel.prompt_history == []
    end
  end

  describe "insert_paste/2" do
    test "no-op for empty text" do
      ui = ui_with_input([""])
      assert UIState.insert_paste(ui, "") == ui
    end

    test "inserts short paste directly" do
      ui = ui_with_input([""])
      ui = UIState.insert_paste(ui, "hello")
      assert UIState.input_text(ui) == "hello"
    end

    test "inserts two-line paste directly" do
      ui = ui_with_input([""])
      ui = UIState.insert_paste(ui, "line1\nline2")
      assert UIState.input_text(ui) == "line1\nline2"
    end

    test "collapses paste with 3+ lines" do
      ui = ui_with_input([""])
      ui = UIState.insert_paste(ui, "a\nb\nc")
      assert length(ui.panel.pasted_blocks) == 1
      assert hd(ui.panel.pasted_blocks).text == "a\nb\nc"
      # prompt_text expands placeholders
      assert UIState.prompt_text(ui) == "a\nb\nc"
    end

    test "strips NUL bytes from paste" do
      ui = ui_with_input([""])
      ui = UIState.insert_paste(ui, "hello\0world")
      assert UIState.input_text(ui) == "helloworld"
    end

    test "multiple collapsed pastes" do
      ui = ui_with_input([""])
      ui = UIState.insert_paste(ui, "a\nb\nc")
      ui = UIState.insert_paste(ui, "d\ne\nf")
      assert length(ui.panel.pasted_blocks) == 2
    end
  end

  describe "toggle_paste_expand/1" do
    test "expands a collapsed block" do
      ui = ui_with_input([""])
      ui = UIState.insert_paste(ui, "line1\nline2\nline3")
      # Move cursor to the placeholder line
      lines = UIState.input_lines(ui)

      placeholder_idx =
        Enum.find_index(lines, &UIState.paste_placeholder?/1)

      ui = set_input_cursor(ui, {placeholder_idx, 0})
      ui = UIState.toggle_paste_expand(ui)

      block = hd(ui.panel.pasted_blocks)
      assert block.expanded
      assert UIState.input_line_count(ui) >= 3
    end

    test "collapses an expanded block" do
      ui = ui_with_input([""])
      ui = UIState.insert_paste(ui, "line1\nline2\nline3")
      lines = UIState.input_lines(ui)

      placeholder_idx =
        Enum.find_index(lines, &UIState.paste_placeholder?/1)

      ui = set_input_cursor(ui, {placeholder_idx, 0})
      # Expand
      ui = UIState.toggle_paste_expand(ui)
      assert hd(ui.panel.pasted_blocks).expanded

      # Set cursor within expanded text
      ui = set_input_cursor(ui, {placeholder_idx, 0})
      # Collapse
      ui = UIState.toggle_paste_expand(ui)
      refute hd(ui.panel.pasted_blocks).expanded
    end

    test "no-op when cursor not on paste" do
      ui = ui_with_input(["hello"])
      ui2 = UIState.toggle_paste_expand(ui)
      assert UIState.input_lines(ui2) == UIState.input_lines(ui)
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
      ui = UIState.new()
      ui = UIState.scroll_up(ui, 5)
      refute ui.panel.scroll.pinned
    end

    test "scroll_down unpins from bottom" do
      ui = UIState.new()
      # First unpin by scrolling up, then scroll down
      ui = put_in(ui.panel.scroll, %{ui.panel.scroll | offset: 10, pinned: false})
      ui = UIState.scroll_down(ui, 3)
      assert ui.panel.scroll.offset == 13
    end
  end

  describe "clear_display/2" do
    test "sets display_start_index and resets scroll" do
      ui = UIState.new()
      ui = UIState.scroll_up(ui, 10)
      ui = UIState.clear_display(ui, 5)
      assert ui.panel.display_start_index == 5
      assert ui.panel.scroll.offset == 0
    end
  end

  describe "ensure_prompt_buffer/1" do
    test "starts buffer when nil" do
      ui = UIState.new()
      ui = UIState.ensure_prompt_buffer(ui)
      assert is_pid(ui.panel.prompt_buffer)
      assert Process.alive?(ui.panel.prompt_buffer)
    end

    test "idempotent when alive" do
      ui = UIState.new()
      ui = UIState.ensure_prompt_buffer(ui)
      pid = ui.panel.prompt_buffer
      ui = UIState.ensure_prompt_buffer(ui)
      assert ui.panel.prompt_buffer == pid
    end

    test "restarts when dead" do
      Process.flag(:trap_exit, true)
      ui = UIState.new()
      ui = UIState.ensure_prompt_buffer(ui)
      old_pid = ui.panel.prompt_buffer
      Process.exit(old_pid, :kill)

      receive do
        {:EXIT, ^old_pid, :killed} -> :ok
      after
        100 -> flunk("expected EXIT")
      end

      ui = UIState.ensure_prompt_buffer(ui)
      assert is_pid(ui.panel.prompt_buffer)
      assert ui.panel.prompt_buffer != old_pid
    end
  end

  describe "Panel.bump_message_version/1" do
    test "increments the counter each call" do
      panel = Panel.new()
      assert panel.message_version == 0

      panel = Panel.bump_message_version(panel)
      assert panel.message_version == 1

      panel = Panel.bump_message_version(panel)
      assert panel.message_version == 2
    end
  end
end
