defmodule Minga.Agent.PromptBufferTest do
  @moduledoc """
  Tests for the prompt Buffer.Server integration in PanelState.

  These verify that the prompt buffer stays in sync with the TextField
  during the migration period. Once TextField is removed, these tests
  become the primary prompt storage tests.
  """

  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Input.TextField

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp focused_panel(text \\ "") do
    panel = PanelState.new()

    panel =
      if text != "" do
        lines = String.split(text, "\n")
        %{panel | input: TextField.from_parts(lines, {0, 0})}
      else
        panel
      end

    PanelState.set_input_focused(panel, true)
  end

  defp buffer_content(panel) do
    BufferServer.content(panel.prompt_buffer)
  end

  # ── Lifecycle ────────────────────────────────────────────────────────────────

  describe "prompt buffer lifecycle" do
    test "new panel has no prompt buffer" do
      panel = PanelState.new()
      assert panel.prompt_buffer == nil
    end

    test "focusing starts the prompt buffer" do
      panel = focused_panel()
      assert is_pid(panel.prompt_buffer)
      assert Process.alive?(panel.prompt_buffer)
    end

    test "prompt buffer starts with empty content" do
      panel = focused_panel()
      assert buffer_content(panel) == ""
    end

    test "prompt buffer starts with existing text if present" do
      panel = focused_panel("existing text")
      assert buffer_content(panel) == "existing text"
    end

    test "ensure_prompt_buffer is idempotent" do
      panel = focused_panel()
      pid1 = panel.prompt_buffer
      panel = PanelState.ensure_prompt_buffer(panel)
      assert panel.prompt_buffer == pid1
    end

    test "ensure_prompt_buffer restarts if process died" do
      Process.flag(:trap_exit, true)
      panel = focused_panel()
      old_pid = panel.prompt_buffer
      Process.exit(old_pid, :kill)

      # Wait for the exit signal to arrive
      receive do
        {:EXIT, ^old_pid, :killed} -> :ok
      after
        100 -> flunk("expected EXIT signal")
      end

      panel = PanelState.ensure_prompt_buffer(panel)
      assert is_pid(panel.prompt_buffer)
      assert panel.prompt_buffer != old_pid
      assert Process.alive?(panel.prompt_buffer)
    end
  end

  # ── Sync on text operations ────────────────────────────────────────────────

  describe "sync on text operations" do
    test "insert_char syncs to prompt buffer" do
      panel = focused_panel()
      panel = PanelState.insert_char(panel, "h")
      panel = PanelState.insert_char(panel, "i")
      assert buffer_content(panel) == "hi"
    end

    test "insert_newline syncs to prompt buffer" do
      panel = focused_panel()
      panel = PanelState.insert_char(panel, "a")
      panel = PanelState.insert_newline(panel)
      panel = PanelState.insert_char(panel, "b")
      assert buffer_content(panel) == "a\nb"
    end

    test "delete_char syncs to prompt buffer" do
      panel = focused_panel("hello")
      panel = %{panel | input: TextField.set_cursor(panel.input, {0, 5})}
      panel = PanelState.delete_char(panel)
      assert buffer_content(panel) == "hell"
    end

    test "clear_input syncs to prompt buffer" do
      panel = focused_panel()
      panel = PanelState.insert_char(panel, "x")
      panel = PanelState.clear_input(panel)
      assert buffer_content(panel) == ""
    end

    test "short paste syncs to prompt buffer" do
      panel = focused_panel()
      panel = PanelState.insert_paste(panel, "pasted")
      assert buffer_content(panel) == "pasted"
    end

    test "history_prev syncs to prompt buffer" do
      panel = focused_panel()
      panel = PanelState.insert_char(panel, "x")
      panel = PanelState.clear_input(panel)
      panel = PanelState.history_prev(panel)
      assert buffer_content(panel) == "x"
    end

    test "history_next syncs to prompt buffer" do
      panel = focused_panel()
      panel = PanelState.insert_char(panel, "a")
      panel = PanelState.clear_input(panel)
      panel = PanelState.insert_char(panel, "b")
      panel = PanelState.clear_input(panel)

      panel = PanelState.history_prev(panel)
      panel = PanelState.history_prev(panel)
      panel = PanelState.history_next(panel)
      assert buffer_content(panel) == "b"
    end
  end

  # ── prompt_text/1 ──────────────────────────────────────────────────────────

  describe "prompt_text/1" do
    test "reads from prompt buffer when available" do
      panel = focused_panel()
      panel = PanelState.insert_char(panel, "x")
      assert PanelState.prompt_text(panel) == "x"
    end

    test "falls back to input_text when no buffer" do
      panel = PanelState.new()
      panel = %{panel | input: TextField.from_parts(["hello"], {0, 5})}
      assert PanelState.prompt_text(panel) == "hello"
    end

    test "substitutes paste placeholders" do
      panel = focused_panel()
      panel = PanelState.insert_paste(panel, "line1\nline2\nline3")
      text = PanelState.prompt_text(panel)
      assert text == "line1\nline2\nline3"
    end
  end
end
