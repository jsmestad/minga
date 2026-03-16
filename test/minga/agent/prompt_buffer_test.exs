defmodule Minga.Agent.PromptBufferTest do
  @moduledoc """
  Tests for the prompt Buffer.Server integration in UIState.

  Now that Buffer.Server is the primary store (not a shadow), these
  verify that all UIState operations correctly delegate to the buffer.
  """

  use ExUnit.Case, async: true

  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp focused_panel(text \\ "") do
    panel = UIState.new()
    panel = UIState.set_input_focused(panel, true)

    if text != "" do
      BufferServer.replace_content(panel.prompt_buffer, text)
    end

    panel
  end

  # ── Lifecycle ────────────────────────────────────────────────────────────────

  describe "prompt buffer lifecycle" do
    test "new panel has no prompt buffer" do
      panel = UIState.new()
      assert panel.prompt_buffer == nil
    end

    test "focusing starts the prompt buffer" do
      panel = focused_panel()
      assert is_pid(panel.prompt_buffer)
      assert Process.alive?(panel.prompt_buffer)
    end

    test "prompt buffer starts with empty content" do
      panel = focused_panel()
      assert BufferServer.content(panel.prompt_buffer) == ""
    end

    test "ensure_prompt_buffer is idempotent" do
      panel = focused_panel()
      pid1 = panel.prompt_buffer
      panel = UIState.ensure_prompt_buffer(panel)
      assert panel.prompt_buffer == pid1
    end

    test "ensure_prompt_buffer restarts if process died" do
      Process.flag(:trap_exit, true)
      panel = focused_panel()
      old_pid = panel.prompt_buffer
      Process.exit(old_pid, :kill)

      receive do
        {:EXIT, ^old_pid, :killed} -> :ok
      after
        100 -> flunk("expected EXIT signal")
      end

      panel = UIState.ensure_prompt_buffer(panel)
      assert is_pid(panel.prompt_buffer)
      assert panel.prompt_buffer != old_pid
      assert Process.alive?(panel.prompt_buffer)
    end
  end

  # ── Text operations write to buffer ────────────────────────────────────────

  describe "text operations" do
    test "insert_char writes to buffer" do
      panel = focused_panel()
      panel = UIState.insert_char(panel, "h")
      panel = UIState.insert_char(panel, "i")
      assert BufferServer.content(panel.prompt_buffer) == "hi"
    end

    test "insert_newline writes to buffer" do
      panel = focused_panel()
      panel = UIState.insert_char(panel, "a")
      panel = UIState.insert_newline(panel)
      panel = UIState.insert_char(panel, "b")
      assert BufferServer.content(panel.prompt_buffer) == "a\nb"
    end

    test "delete_char writes to buffer" do
      panel = focused_panel("hello")
      BufferServer.set_cursor(panel.prompt_buffer, {0, 5})
      panel = UIState.delete_char(panel)
      assert BufferServer.content(panel.prompt_buffer) == "hell"
    end

    test "clear_input empties buffer" do
      panel = focused_panel()
      panel = UIState.insert_char(panel, "x")
      panel = UIState.clear_input(panel)
      assert BufferServer.content(panel.prompt_buffer) == ""
    end

    test "short paste writes to buffer" do
      panel = focused_panel()
      panel = UIState.insert_paste(panel, "pasted")
      assert BufferServer.content(panel.prompt_buffer) == "pasted"
    end

    test "history_prev writes to buffer" do
      panel = focused_panel()
      panel = UIState.insert_char(panel, "x")
      panel = UIState.clear_input(panel)
      panel = UIState.history_prev(panel)
      assert BufferServer.content(panel.prompt_buffer) == "x"
    end

    test "history_next writes to buffer" do
      panel = focused_panel()
      panel = UIState.insert_char(panel, "a")
      panel = UIState.clear_input(panel)
      panel = UIState.insert_char(panel, "b")
      panel = UIState.clear_input(panel)

      panel = UIState.history_prev(panel)
      panel = UIState.history_prev(panel)
      panel = UIState.history_next(panel)
      assert BufferServer.content(panel.prompt_buffer) == "b"
    end
  end

  # ── Accessor consistency ───────────────────────────────────────────────────

  describe "accessor consistency" do
    test "input_lines matches buffer content" do
      panel = focused_panel("hello\nworld")
      assert UIState.input_lines(panel) == ["hello", "world"]
    end

    test "input_cursor matches buffer cursor" do
      panel = focused_panel("hello")
      BufferServer.set_cursor(panel.prompt_buffer, {0, 3})
      assert UIState.input_cursor(panel) == {0, 3}
    end

    test "input_line_count matches buffer" do
      panel = focused_panel("a\nb\nc")
      assert UIState.input_line_count(panel) == 3
    end

    test "input_empty? reflects buffer state" do
      panel = focused_panel()
      assert UIState.input_empty?(panel)
      panel = UIState.insert_char(panel, "x")
      refute UIState.input_empty?(panel)
    end
  end
end
