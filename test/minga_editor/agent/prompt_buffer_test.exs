defmodule MingaEditor.Agent.PromptBufferTest do
  @moduledoc """
  Tests for the prompt Buffer.Process integration in UIState.

  Now that Buffer.Process is the primary store (not a shadow), these
  verify that all UIState operations correctly delegate to the buffer.
  """

  use ExUnit.Case, async: true

  alias MingaAgent.DraftSnapshot
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias Minga.Buffer.Process, as: BufferProcess

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp focused_panel(text \\ "") do
    panel = UIState.new()
    panel = MingaEditor.Agent.PromptBuffer.set_input_focused(panel, true)

    if text != "" do
      BufferProcess.replace_content(panel.panel.prompt_buffer, text)
    end

    panel
  end

  # ── Lifecycle ────────────────────────────────────────────────────────────────

  describe "prompt buffer lifecycle" do
    test "new panel has no prompt buffer" do
      panel = UIState.new()
      assert panel.panel.prompt_buffer == nil
    end

    test "focusing starts the prompt buffer" do
      panel = focused_panel()
      assert is_pid(panel.panel.prompt_buffer)
      assert Process.alive?(panel.panel.prompt_buffer)
    end

    test "prompt buffer starts with empty content" do
      panel = focused_panel()
      assert BufferProcess.content(panel.panel.prompt_buffer) == ""
    end

    test "ensure_prompt_buffer is idempotent" do
      panel = focused_panel()
      pid1 = panel.panel.prompt_buffer
      panel = MingaEditor.Agent.PromptBuffer.ensure(panel)
      assert panel.panel.prompt_buffer == pid1
    end

    test "ensure_prompt_buffer restarts if process died" do
      Process.flag(:trap_exit, true)
      panel = focused_panel()
      old_pid = panel.panel.prompt_buffer
      Process.exit(old_pid, :kill)

      receive do
        {:EXIT, ^old_pid, :killed} -> :ok
      after
        100 -> flunk("expected EXIT signal")
      end

      panel = MingaEditor.Agent.PromptBuffer.ensure(panel)
      assert is_pid(panel.panel.prompt_buffer)
      assert panel.panel.prompt_buffer != old_pid
      assert Process.alive?(panel.panel.prompt_buffer)
    end
  end

  # ── Text operations write to buffer ────────────────────────────────────────

  describe "text operations" do
    test "insert_char writes to buffer" do
      panel = focused_panel()
      panel = MingaEditor.Agent.PromptBuffer.insert_char(panel, "h")
      panel = MingaEditor.Agent.PromptBuffer.insert_char(panel, "i")
      assert BufferProcess.content(panel.panel.prompt_buffer) == "hi"
    end

    test "insert_newline writes to buffer" do
      panel = focused_panel()
      panel = MingaEditor.Agent.PromptBuffer.insert_char(panel, "a")
      panel = MingaEditor.Agent.PromptBuffer.insert_newline(panel)
      panel = MingaEditor.Agent.PromptBuffer.insert_char(panel, "b")
      assert BufferProcess.content(panel.panel.prompt_buffer) == "a\nb"
    end

    test "delete_char writes to buffer" do
      panel = focused_panel("hello")
      BufferProcess.move_to(panel.panel.prompt_buffer, {0, 5})
      panel = MingaEditor.Agent.PromptBuffer.delete_char(panel)
      assert BufferProcess.content(panel.panel.prompt_buffer) == "hell"
    end

    test "clear_input empties buffer" do
      panel = focused_panel()
      panel = MingaEditor.Agent.PromptBuffer.insert_char(panel, "x")
      panel = MingaEditor.Agent.PromptBuffer.clear_input(panel)
      assert BufferProcess.content(panel.panel.prompt_buffer) == ""
    end

    test "short paste writes to buffer" do
      panel = focused_panel()
      panel = MingaEditor.Agent.PromptBuffer.insert_paste(panel, "pasted")
      assert BufferProcess.content(panel.panel.prompt_buffer) == "pasted"
    end

    test "history_prev writes to buffer" do
      panel = focused_panel()
      panel = MingaEditor.Agent.PromptBuffer.insert_char(panel, "x")
      panel = MingaEditor.Agent.PromptBuffer.clear_input(panel)
      panel = MingaEditor.Agent.PromptBuffer.history_prev(panel)
      assert BufferProcess.content(panel.panel.prompt_buffer) == "x"
    end

    test "history_next writes to buffer" do
      panel = focused_panel()
      panel = MingaEditor.Agent.PromptBuffer.insert_char(panel, "a")
      panel = MingaEditor.Agent.PromptBuffer.clear_input(panel)
      panel = MingaEditor.Agent.PromptBuffer.insert_char(panel, "b")
      panel = MingaEditor.Agent.PromptBuffer.clear_input(panel)

      panel = MingaEditor.Agent.PromptBuffer.history_prev(panel)
      panel = MingaEditor.Agent.PromptBuffer.history_prev(panel)
      panel = MingaEditor.Agent.PromptBuffer.history_next(panel)
      assert BufferProcess.content(panel.panel.prompt_buffer) == "b"
    end
  end

  describe "paste toggles" do
    test "round-trips paste text with empty lines and collapses from an interior byte cursor" do
      paste = "first\ncafé text\n\nlast"
      ui = focused_panel("before\n\nafter")
      buffer = ui.panel.prompt_buffer
      BufferProcess.move_to(buffer, {1, 0})
      ui = PromptBuffer.insert_paste(ui, paste)
      compact = "before\n\0PASTE:0\nafter"
      submitted = "before\n#{paste}\nafter"

      assert BufferProcess.content_and_cursor(buffer) == {compact, {2, 0}}
      assert PromptBuffer.prompt_text(ui) == submitted
      assert [%{text: ^paste, expanded: false}] = ui.panel.pasted_blocks

      BufferProcess.move_to(buffer, {1, 3})
      expanded = PromptBuffer.toggle_paste_expand(ui)

      assert BufferProcess.content_and_cursor(buffer) == {submitted, {1, 0}}
      assert PromptBuffer.prompt_text(expanded) == submitted
      assert [%{text: ^paste, expanded: true}] = expanded.panel.pasted_blocks

      BufferProcess.move_to(buffer, {2, 5})
      assert {:handled, collapsed} = PromptBuffer.toggle_paste_at_cursor(expanded)

      assert BufferProcess.content_and_cursor(buffer) == {compact, {1, 0}}
      assert PromptBuffer.prompt_text(collapsed) == submitted
      assert [%{text: ^paste, expanded: false}] = collapsed.panel.pasted_blocks
    end

    test "a duplicate compact token expands the first canonical token and shifts the cursor" do
      paste = "first\n\nlast"
      ui = focused_panel("before\n\0PASTE:0\nbetween\n\0PASTE:0\nafter")
      ui = UIState.append_paste_block(ui, paste)
      buffer = ui.panel.prompt_buffer
      BufferProcess.move_to(buffer, {3, 4})

      assert {:handled, expanded} = PromptBuffer.toggle_paste_at_cursor(ui)

      assert BufferProcess.content_and_cursor(buffer) ==
               {"before\n#{paste}\nbetween\n\0PASTE:0\nafter", {5, 0}}

      assert PromptBuffer.prompt_text(expanded) == "before\n#{paste}\nbetween\n#{paste}\nafter"
      assert [%{text: ^paste, expanded: true}] = expanded.panel.pasted_blocks
    end

    test "a later expanded duplicate does not prevent another block's first match from collapsing" do
      first = "aa\nbb\ncc"
      second = "divider\naa\nbb"

      ui =
        focused_panel("#{first}\ndivider\n#{first}")
        |> UIState.append_paste_block(first)
        |> UIState.mark_paste_expanded(0, true)
        |> UIState.append_paste_block(second)
        |> UIState.mark_paste_expanded(1, true)

      buffer = ui.panel.prompt_buffer
      BufferProcess.move_to(buffer, {5, 1})

      assert {:handled, collapsed} = PromptBuffer.toggle_paste_at_cursor(ui)
      assert BufferProcess.content_and_cursor(buffer) == {"#{first}\n\0PASTE:1\ncc", {3, 0}}
      assert PromptBuffer.prompt_text(collapsed) == "#{first}\ndivider\n#{first}"

      assert [%{text: ^first, expanded: true}, %{text: ^second, expanded: false}] =
               collapsed.panel.pasted_blocks
    end
  end

  describe "draft capture" do
    test "keeps Unicode cursor bytes, leading whitespace, and live pasted content" do
      draft = focused_panel("  café界\n")
      BufferProcess.move_to(draft.panel.prompt_buffer, {1, 0})
      draft = PromptBuffer.insert_paste(draft, "one\ntwo\nthree\nfour")
      BufferProcess.move_to(draft.panel.prompt_buffer, {0, 7})

      assert {:ok,
              %DraftSnapshot{
                text: "  café界\n\0PASTE:0",
                cursor: {0, 7},
                paste_blocks: [{"one\ntwo\nthree\nfour", false}]
              }} = PromptBuffer.draft_snapshot(draft, [])
    end

    test "does not retain deleted paste payloads or credential drafts" do
      draft = PromptBuffer.insert_paste(focused_panel(), "discard\nthis\nprivate\npaste")
      BufferProcess.replace_content(draft.panel.prompt_buffer, "current")

      assert {:ok, %DraftSnapshot{text: "current", paste_blocks: [{"", false}]}} =
               PromptBuffer.draft_snapshot(draft, [])

      for private <- ["/auth openai synthetic-key", " \t/login --complete synthetic-callback"] do
        assert {:error, :private_input} = PromptBuffer.draft_snapshot(focused_panel(private), [])
      end

      collapsed =
        PromptBuffer.insert_paste(focused_panel(), "/auth openai synthetic-key\nx\ny\nz")

      assert {:error, :private_input} = PromptBuffer.draft_snapshot(collapsed, [])
    end

    test "restores the saved prompt into a new composer without replacing an attached draft" do
      original =
        focused_panel()
        |> PromptBuffer.insert_paste("one\ntwo\nthree\nfour")

      assert {:ok, saved} = PromptBuffer.draft_snapshot(original, [])
      live = focused_panel("newer input")
      assert {:error, :composer_attached} = PromptBuffer.restore_draft(live, saved)
      assert PromptBuffer.input_text(live) == "newer input"

      assert {:ok, restored} = PromptBuffer.restore_draft(UIState.new(), saved)
      assert PromptBuffer.input_cursor(restored) == saved.cursor
      expanded = PromptBuffer.toggle_paste_expand(restored)
      assert PromptBuffer.input_text(expanded) == "one\ntwo\nthree\nfour"
    end
  end

  # ── Accessor consistency ───────────────────────────────────────────────────

  describe "accessor consistency" do
    test "input_lines matches buffer content" do
      panel = focused_panel("hello\nworld")
      assert MingaEditor.Agent.PromptBuffer.input_lines(panel) == ["hello", "world"]
    end

    test "input_cursor matches buffer cursor" do
      panel = focused_panel("hello")
      BufferProcess.move_to(panel.panel.prompt_buffer, {0, 3})
      assert MingaEditor.Agent.PromptBuffer.input_cursor(panel) == {0, 3}
    end

    test "input_line_count matches buffer" do
      panel = focused_panel("a\nb\nc")
      assert MingaEditor.Agent.PromptBuffer.input_line_count(panel) == 3
    end

    test "input_empty? reflects buffer state" do
      panel = focused_panel()
      assert MingaEditor.Agent.PromptBuffer.input_empty?(panel)
      panel = MingaEditor.Agent.PromptBuffer.insert_char(panel, "x")
      refute MingaEditor.Agent.PromptBuffer.input_empty?(panel)
    end
  end
end
