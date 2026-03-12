defmodule Minga.Agent.PromptCharacterizationTest do
  @moduledoc """
  Characterization tests for the agent prompt editing flow.

  These pin the current behavior of the prompt so that Phase D
  (replacing TextField with Buffer.Server) can verify no regressions.
  Each test documents a specific behavior that must be preserved.

  The prompt flow involves three layers:
  1. PanelState — owns TextField, vim state, history, paste blocks
  2. Input.Vim — vim grammar on TextField (insert/normal/visual modes)
  3. AgentPanel input handler — routes keys to Vim, handles Enter/Escape

  Phase D replaces layers 1-2 with Buffer.Server + the real Mode FSM.
  Layer 3 (AgentPanel) needs minimal changes: Enter still submits,
  Escape still exits insert mode, domain keys still work.
  """

  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Input.TextField
  alias Minga.Input.Vim

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_panel(text \\ "") do
    panel = PanelState.new()

    if text == "" do
      panel
    else
      lines = String.split(text, "\n")
      %{panel | input: TextField.from_parts(lines, {0, 0})}
    end
  end

  defp focused_panel(text \\ "") do
    panel = new_panel(text)
    PanelState.set_input_focused(panel, true)
  end

  defp type_text(panel, text) do
    String.graphemes(text)
    |> Enum.reduce(panel, fn char, acc ->
      PanelState.insert_char(acc, char)
    end)
  end

  defp vim_key(panel, codepoint, mods \\ 0) do
    case Vim.handle_key(panel.vim, panel.input, codepoint, mods) do
      {:handled, new_vim, new_tf} ->
        %{panel | vim: new_vim, input: new_tf}

      :not_handled ->
        panel
    end
  end

  defp enter_normal(panel) do
    {new_vim, new_tf} = Vim.enter_normal(panel.vim, panel.input)
    %{panel | vim: new_vim, input: new_tf}
  end

  # ── Prompt text lifecycle ──────────────────────────────────────────────────

  describe "prompt text lifecycle" do
    test "empty panel has empty text" do
      panel = new_panel()
      assert PanelState.input_text(panel) == ""
    end

    test "typing characters builds up text" do
      panel = focused_panel() |> type_text("hello world")
      assert PanelState.input_text(panel) == "hello world"
    end

    test "newlines create multi-line prompts" do
      panel = focused_panel() |> type_text("line 1")
      panel = PanelState.insert_newline(panel)
      panel = type_text(panel, "line 2")
      assert PanelState.input_text(panel) == "line 1\nline 2"
    end

    test "clear_input empties and saves to history" do
      panel = focused_panel() |> type_text("remember me")
      panel = PanelState.clear_input(panel)
      assert PanelState.input_text(panel) == ""
      assert panel.prompt_history == ["remember me"]
    end

    test "clear_input does not save empty text to history" do
      panel = focused_panel()
      panel = PanelState.clear_input(panel)
      assert panel.prompt_history == []
    end

    test "delete_char removes character before cursor" do
      panel = focused_panel() |> type_text("hello")
      panel = PanelState.delete_char(panel)
      assert PanelState.input_text(panel) == "hell"
    end
  end

  # ── Vim mode integration ───────────────────────────────────────────────────

  describe "vim mode integration" do
    test "focused panel starts in insert mode" do
      panel = focused_panel()
      assert PanelState.input_mode(panel) == :insert
    end

    test "escape switches to normal mode" do
      panel = focused_panel() |> type_text("hello")
      panel = enter_normal(panel)
      assert PanelState.input_mode(panel) == :normal
    end

    test "cursor moves left in normal mode via h key" do
      panel = focused_panel() |> type_text("hello")
      panel = enter_normal(panel)
      # Cursor should be at end of "hello" after entering normal (moves back 1)
      {_, col_before} = panel.input.cursor
      panel = vim_key(panel, ?h)
      {_, col_after} = panel.input.cursor
      assert col_after < col_before
    end

    test "cursor moves right in normal mode via l key" do
      panel = focused_panel() |> type_text("hello")
      panel = enter_normal(panel)
      # Move left first to have room to move right
      panel = vim_key(panel, ?h)
      panel = vim_key(panel, ?h)
      {_, col_before} = panel.input.cursor
      panel = vim_key(panel, ?l)
      {_, col_after} = panel.input.cursor
      assert col_after > col_before
    end

    test "w moves to next word in normal mode" do
      panel = new_panel("hello world foo")
      panel = PanelState.set_input_focused(panel, true)
      panel = enter_normal(panel)
      # Cursor at 0,0; w should move to "world"
      panel = vim_key(panel, ?w)
      {_, col} = panel.input.cursor
      assert col == 6
    end

    test "b moves to previous word in normal mode" do
      panel = new_panel("hello world foo")
      panel = %{panel | input: TextField.set_cursor(panel.input, {0, 12})}
      panel = PanelState.set_input_focused(panel, true)
      panel = enter_normal(panel)
      panel = vim_key(panel, ?b)
      {_, col} = panel.input.cursor
      assert col == 6
    end

    test "dd deletes current line in normal mode" do
      panel = new_panel("line 1\nline 2\nline 3")
      panel = %{panel | input: TextField.set_cursor(panel.input, {1, 0})}
      panel = PanelState.set_input_focused(panel, true)
      panel = enter_normal(panel)
      panel = vim_key(panel, ?d)
      panel = vim_key(panel, ?d)
      text = PanelState.input_text(panel)
      assert text == "line 1\nline 3"
    end

    test "x deletes character at cursor in normal mode" do
      panel = new_panel("hello")
      panel = PanelState.set_input_focused(panel, true)
      panel = enter_normal(panel)
      panel = vim_key(panel, ?x)
      assert PanelState.input_text(panel) == "ello"
    end

    test "i enters insert mode from normal" do
      panel = new_panel("hello")
      panel = PanelState.set_input_focused(panel, true)
      panel = enter_normal(panel)
      assert PanelState.input_mode(panel) == :normal
      panel = vim_key(panel, ?i)
      assert PanelState.input_mode(panel) == :insert
    end

    test "A enters insert mode at end of line" do
      panel = new_panel("hello")
      panel = PanelState.set_input_focused(panel, true)
      panel = enter_normal(panel)
      panel = vim_key(panel, ?A)
      assert PanelState.input_mode(panel) == :insert
      {_, col} = panel.input.cursor
      assert col == 5
    end
  end

  # ── History recall ─────────────────────────────────────────────────────────

  describe "history recall" do
    test "history_prev recalls the last submitted prompt" do
      panel = focused_panel() |> type_text("first prompt")
      panel = PanelState.clear_input(panel)
      panel = type_text(panel, "second prompt")
      panel = PanelState.clear_input(panel)

      # Recall: most recent first
      panel = PanelState.history_prev(panel)
      assert PanelState.input_text(panel) == "second prompt"

      panel = PanelState.history_prev(panel)
      assert PanelState.input_text(panel) == "first prompt"
    end

    test "history_next moves forward after history_prev" do
      panel = focused_panel() |> type_text("prompt a")
      panel = PanelState.clear_input(panel)
      panel = type_text(panel, "prompt b")
      panel = PanelState.clear_input(panel)

      panel = PanelState.history_prev(panel)
      panel = PanelState.history_prev(panel)
      panel = PanelState.history_next(panel)
      assert PanelState.input_text(panel) == "prompt b"
    end

    test "history_next past newest returns empty" do
      panel = focused_panel() |> type_text("only one")
      panel = PanelState.clear_input(panel)

      panel = PanelState.history_prev(panel)
      assert PanelState.input_text(panel) == "only one"

      panel = PanelState.history_next(panel)
      assert PanelState.input_text(panel) == ""
    end

    test "editing after history recall resets history index" do
      panel = focused_panel() |> type_text("saved")
      panel = PanelState.clear_input(panel)

      panel = PanelState.history_prev(panel)
      assert panel.history_index == 0

      panel = PanelState.insert_char(panel, "x")
      assert panel.history_index == -1
    end
  end

  # ── Paste block handling ───────────────────────────────────────────────────

  describe "paste block handling" do
    test "short paste inserts inline" do
      panel = focused_panel()
      panel = PanelState.insert_paste(panel, "ab")
      assert PanelState.input_text(panel) == "ab"
      assert panel.pasted_blocks == []
    end

    test "long paste creates collapsed block" do
      panel = focused_panel()
      long_text = "line1\nline2\nline3"
      panel = PanelState.insert_paste(panel, long_text)
      assert length(panel.pasted_blocks) == 1
      # input_text should substitute the placeholder with full content
      assert PanelState.input_text(panel) == long_text
    end

    test "toggle expands and collapses paste block" do
      panel = focused_panel()
      long_text = "aaa\nbbb\nccc"
      panel = PanelState.insert_paste(panel, long_text)

      # Should be collapsed (1 placeholder line)
      assert PanelState.input_line_count(panel) == 1

      # Expand: should show the actual lines
      panel = PanelState.toggle_paste_expand(panel)
      assert PanelState.input_line_count(panel) == 3

      # Collapse back
      panel = %{panel | input: TextField.set_cursor(panel.input, {0, 0})}
      panel = PanelState.toggle_paste_expand(panel)
      assert PanelState.input_line_count(panel) == 1
    end

    test "input_text returns same content expanded or collapsed" do
      panel = focused_panel()
      long_text = "line1\nline2\nline3"
      panel = PanelState.insert_paste(panel, long_text)

      text_collapsed = PanelState.input_text(panel)
      panel = PanelState.toggle_paste_expand(panel)
      text_expanded = PanelState.input_text(panel)

      assert text_collapsed == text_expanded
    end

    test "clear_input removes paste blocks" do
      panel = focused_panel()
      panel = PanelState.insert_paste(panel, "a\nb\nc")
      assert length(panel.pasted_blocks) == 1

      panel = PanelState.clear_input(panel)
      assert panel.pasted_blocks == []
    end
  end

  # ── Focus management ───────────────────────────────────────────────────────

  describe "focus management" do
    test "set_input_focused true enters insert mode" do
      panel = new_panel("hello")
      panel = PanelState.set_input_focused(panel, true)
      assert panel.input_focused == true
      assert PanelState.input_mode(panel) == :insert
    end

    test "set_input_focused false preserves insert mode" do
      # When unfocusing, vim stays in insert so re-focusing is seamless
      panel = focused_panel() |> type_text("hello")
      panel = PanelState.set_input_focused(panel, false)
      assert panel.input_focused == false
      assert PanelState.input_mode(panel) == :insert
    end
  end

  # ── Multi-line editing ─────────────────────────────────────────────────────

  describe "multi-line editing" do
    test "cursor navigation across lines" do
      panel = focused_panel()
      panel = type_text(panel, "first line")
      panel = PanelState.insert_newline(panel)
      panel = type_text(panel, "second line")

      assert PanelState.input_line_count(panel) == 2
      {line, _col} = panel.input.cursor
      assert line == 1

      # Move cursor up
      result = PanelState.move_cursor_up(panel)
      {line, _col} = result.input.cursor
      assert line == 0

      # Move cursor up from first line returns :at_top
      assert PanelState.move_cursor_up(result) == :at_top
    end

    test "backspace at start of line joins with previous" do
      panel = focused_panel()
      panel = type_text(panel, "hello")
      panel = PanelState.insert_newline(panel)
      panel = type_text(panel, "world")

      # Move to start of line 2
      panel = %{panel | input: TextField.set_cursor(panel.input, {1, 0})}
      panel = PanelState.delete_char(panel)
      assert PanelState.input_text(panel) == "helloworld"
      assert PanelState.input_line_count(panel) == 1
    end
  end
end
