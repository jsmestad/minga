defmodule Minga.Agent.PromptCharacterizationTest do
  @moduledoc """
  Characterization tests for the agent prompt editing flow.

  These pin the observable behavior of the prompt so regressions are
  caught mechanically. The prompt is backed by a Buffer.Server and
  edited via the standard Mode FSM (same pipeline as file buffers).

  The prompt has three concerns:

  1. **Text storage** — `Buffer.Server` (gap buffer). All text mutations
     (insert, delete, newline) go through GenServer calls.

  2. **Vim editing** — The standard Mode FSM handles motions, operators,
     visual mode, text objects, undo/redo. Keys are routed through
     `dispatch_prompt_via_mode_fsm`, which swaps the active buffer to
     the prompt buffer and runs the key through the same pipeline file
     buffers use.

  3. **Domain behavior** — Enter submits, history recall (up/down),
     paste block collapsing, @-mention completion. These are handled
     by PanelState and the agent command handlers.
  """

  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Buffer.Server, as: BufferServer

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_panel do
    panel = PanelState.new()
    PanelState.set_input_focused(panel, true)
  end

  defp with_text(text) do
    panel = new_panel()
    BufferServer.replace_content(panel.prompt_buffer, text)
    panel
  end

  # ── Prompt text lifecycle ────────────────────────────────────────────────────

  describe "prompt text lifecycle" do
    test "empty panel has empty prompt text" do
      panel = new_panel()
      assert PanelState.prompt_text(panel) == ""
    end

    test "insert_char accumulates text" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "h")
      panel = PanelState.insert_char(panel, "i")
      assert PanelState.prompt_text(panel) == "hi"
    end

    test "insert_newline splits lines" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "a")
      panel = PanelState.insert_newline(panel)
      panel = PanelState.insert_char(panel, "b")
      assert PanelState.prompt_text(panel) == "a\nb"
    end

    test "clear_input saves to history and empties" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "x")
      panel = PanelState.clear_input(panel)
      assert PanelState.prompt_text(panel) == ""
      assert panel.prompt_history == ["x"]
    end

    test "delete_char removes last character" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "a")
      panel = PanelState.insert_char(panel, "b")
      panel = PanelState.delete_char(panel)
      assert PanelState.prompt_text(panel) == "a"
    end

    test "delete_char no-op at buffer start" do
      panel = new_panel()
      panel = PanelState.delete_char(panel)
      assert PanelState.prompt_text(panel) == ""
    end
  end

  # ── History recall ───────────────────────────────────────────────────────────

  describe "history recall" do
    test "history_prev recalls saved entry" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "x")
      panel = PanelState.clear_input(panel)
      panel = PanelState.history_prev(panel)
      assert PanelState.prompt_text(panel) == "x"
    end

    test "history_next returns to empty" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "x")
      panel = PanelState.clear_input(panel)
      panel = PanelState.history_prev(panel)
      panel = PanelState.history_next(panel)
      assert PanelState.prompt_text(panel) == ""
    end

    test "history round-trip through multiple entries" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "a")
      panel = PanelState.clear_input(panel)
      panel = PanelState.insert_char(panel, "b")
      panel = PanelState.clear_input(panel)

      panel = PanelState.history_prev(panel)
      assert PanelState.prompt_text(panel) == "b"
      panel = PanelState.history_prev(panel)
      assert PanelState.prompt_text(panel) == "a"
      panel = PanelState.history_next(panel)
      assert PanelState.prompt_text(panel) == "b"
    end

    test "editing resets history index" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "x")
      panel = PanelState.clear_input(panel)
      panel = PanelState.history_prev(panel)
      panel = PanelState.insert_char(panel, "y")
      assert panel.history_index == -1
    end
  end

  # ── Paste block handling ─────────────────────────────────────────────────────

  describe "paste block handling" do
    test "short paste inserts directly" do
      panel = new_panel()
      panel = PanelState.insert_paste(panel, "short")
      assert PanelState.prompt_text(panel) == "short"
      assert panel.pasted_blocks == []
    end

    test "long paste creates collapsed block" do
      panel = new_panel()
      panel = PanelState.insert_paste(panel, "line1\nline2\nline3")
      assert length(panel.pasted_blocks) == 1
      assert hd(panel.pasted_blocks).text == "line1\nline2\nline3"
      # prompt_text substitutes placeholder
      assert PanelState.prompt_text(panel) == "line1\nline2\nline3"
    end

    test "clear_input removes paste blocks" do
      panel = new_panel()
      panel = PanelState.insert_paste(panel, "a\nb\nc")
      panel = PanelState.clear_input(panel)
      assert panel.pasted_blocks == []
    end
  end

  # ── Focus management ─────────────────────────────────────────────────────────

  describe "focus management" do
    test "focusing starts prompt buffer" do
      panel = PanelState.new()
      panel = PanelState.set_input_focused(panel, true)
      assert panel.input_focused
      assert is_pid(panel.prompt_buffer)
    end

    test "unfocusing preserves buffer content" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "x")
      panel = PanelState.set_input_focused(panel, false)
      refute panel.input_focused
      assert PanelState.prompt_text(panel) == "x"
    end
  end

  # ── Multi-line editing ───────────────────────────────────────────────────────

  describe "multi-line editing" do
    test "cursor moves between lines" do
      panel = new_panel()
      panel = PanelState.insert_char(panel, "a")
      panel = PanelState.insert_newline(panel)
      panel = PanelState.insert_char(panel, "b")

      result = PanelState.move_cursor_up(panel)
      refute result == :at_top
    end

    test "backspace joins lines" do
      panel = with_text("ab\ncd")
      BufferServer.set_cursor(panel.prompt_buffer, {1, 0})
      panel = PanelState.delete_char(panel)
      assert PanelState.input_lines(panel) == ["abcd"]
    end
  end
end
