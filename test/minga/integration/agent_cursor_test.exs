defmodule Minga.Integration.AgentCursorTest do
  @moduledoc """
  Integration tests for cursor positioning in the agentic view.

  Reproduces a regression where pressing `i` to focus the prompt input
  places the cursor on the "╭─ Prompt ─..." border line instead of the
  actual input content row below it. The user can type in the correct
  area, but the visible cursor is one row too high.
  """

  # async: false — headless editors under high concurrency can destabilize
  # ExUnit's :standard_error process registration during teardown
  use Minga.Test.EditorCase, async: false

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Window
  alias Minga.Test.HeadlessPort
  alias Minga.Test.StubServer

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Starts a headless editor in agent mode (agent chat window, :agent keymap).
  # Mirrors the state Minga boots into by default.
  @spec start_agent_editor(keyword()) :: map()
  defp start_agent_editor(opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    id = :erlang.unique_integer([:positive])

    {:ok, port} = HeadlessPort.start_link(width: width, height: height)

    agent_buf = AgentBufferSync.start_buffer()
    assert is_pid(agent_buf), "Failed to start agent buffer"

    {:ok, file_buf} = BufferServer.start_link(content: "", buffer_name: "unnamed")

    {:ok, editor} =
      Editor.start_link(
        name: :"headless_agent_cursor_#{id}",
        port_manager: port,
        buffer: file_buf,
        width: width,
        height: height
      )

    {:ok, fake_session} = StubServer.start_link()

    :sys.replace_state(editor, fn state ->
      win_id = state.windows.active
      agent_window = Window.new_agent_chat(win_id, agent_buf, height, width)

      windows = %{
        state.windows
        | map: Map.put(state.windows.map, win_id, agent_window)
      }

      agent_tab_bar = TabBar.new(Tab.new_agent(1, "Agent"))

      agent_state =
        state.agent
        |> Map.put(:buffer, agent_buf)
        |> Map.put(:session, fake_session)

      %{
        state
        | windows: windows,
          tab_bar: agent_tab_bar,
          keymap_scope: :agent,
          agent: agent_state
      }
    end)

    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    {:ok, _snapshot} = HeadlessPort.collect_frame(ref)

    %{
      editor: editor,
      buffer: file_buf,
      agent_buffer: agent_buf,
      port: port,
      width: width,
      height: height
    }
  end

  # Finds the first row number containing the given text substring.
  @spec find_row_containing([String.t()], String.t()) :: non_neg_integer() | nil
  defp find_row_containing(rows, text) do
    Enum.find_index(rows, &String.contains?(&1, text))
  end

  # Finds the last row number containing the given text substring.
  # Useful for finding the modeline when the same text appears in other UI areas.
  @spec find_last_row_containing([String.t()], String.t()) :: non_neg_integer() | nil
  defp find_last_row_containing(rows, text) do
    rows
    |> Enum.with_index()
    |> Enum.filter(fn {row, _idx} -> String.contains?(row, text) end)
    |> List.last()
    |> case do
      {_row, idx} -> idx
      nil -> nil
    end
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "agent prompt cursor positioning" do
    test "cursor lands on input content row, not the border" do
      ctx = start_agent_editor()

      # Press i to focus the prompt input (enters insert mode)
      send_keys_sync(ctx, "i")

      rows = screen_text(ctx)
      {cursor_row, _cursor_col} = screen_cursor(ctx)

      # Find the row with the prompt border and the row with the placeholder text
      border_row = find_row_containing(rows, "Prompt")
      content_row = find_row_containing(rows, "Type a message")

      assert border_row != nil, "Should find the Prompt border row on screen"
      assert content_row != nil, "Should find the input content row on screen"
      assert border_row < content_row, "Border should be above the content row"

      assert cursor_row == content_row,
             "Cursor should be on the input content row (#{content_row}), " <>
               "not the border row (#{border_row}). Got cursor at row #{cursor_row}."
    end

    test "cursor stays on content row after typing" do
      ctx = start_agent_editor()

      send_keys_sync(ctx, "i")
      type_text(ctx, "hello")

      rows = screen_text(ctx)
      {cursor_row, _cursor_col} = screen_cursor(ctx)

      # After typing, the row should contain our text
      typed_row = find_row_containing(rows, "hello")
      assert typed_row != nil, "Should find typed text on screen"

      assert cursor_row == typed_row,
             "Cursor should be on the row with typed text (#{typed_row}), " <>
               "got row #{cursor_row}."
    end

    test "cursor row matches content row at different terminal sizes" do
      for {width, height} <- [{80, 24}, {120, 40}, {60, 20}] do
        ctx = start_agent_editor(width: width, height: height)

        send_keys_sync(ctx, "i")

        rows = screen_text(ctx)
        {cursor_row, _cursor_col} = screen_cursor(ctx)

        content_row = find_row_containing(rows, "Type a message")

        assert content_row != nil,
               "Should find input content row at #{width}x#{height}"

        assert cursor_row == content_row,
               "At #{width}x#{height}: cursor should be on row #{content_row}, " <>
                 "got row #{cursor_row}."
      end
    end
  end

  describe "agent modeline" do
    test "modeline shows vim mode and model name in agent view" do
      ctx = start_agent_editor()

      rows = screen_text(ctx)

      # The modeline is the last row containing the model name (the sidebar
      # also shows it, so we need the bottom-most occurrence).
      modeline_idx = find_last_row_containing(rows, "claude-sonnet-4")
      assert modeline_idx != nil, "Should find model name in the modeline"

      modeline_text = Enum.at(rows, modeline_idx)

      assert String.contains?(modeline_text, "NORMAL"),
             "Modeline should show NORMAL mode, got: #{modeline_text}"
    end

    test "modeline shows INSERT mode after focusing input" do
      ctx = start_agent_editor()

      send_keys_sync(ctx, "i")

      rows = screen_text(ctx)

      modeline_idx = find_last_row_containing(rows, "claude-sonnet-4")
      assert modeline_idx != nil, "Should find modeline with model name"

      modeline_text = Enum.at(rows, modeline_idx)

      assert String.contains?(modeline_text, "INSERT"),
             "Modeline should show INSERT mode after pressing i, got: #{modeline_text}"
    end

    test "modeline is below the input area" do
      ctx = start_agent_editor()

      rows = screen_text(ctx)

      prompt_row = find_row_containing(rows, "Prompt")
      modeline_row = find_last_row_containing(rows, "claude-sonnet-4")

      assert prompt_row != nil, "Should find the prompt border"
      assert modeline_row != nil, "Should find the modeline"
      assert modeline_row > prompt_row, "Modeline should be below the prompt border"
    end
  end
end
