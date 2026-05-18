defmodule Minga.Integration.AgentCursorTest do
  @moduledoc """
  Integration tests for cursor positioning in the agentic view.

  Reproduces a regression where pressing `i` to focus the prompt input
  places the cursor on the "╭─ Prompt ─..." border line instead of the
  actual input content row below it. The user can type in the correct
  area, but the visible cursor is one row too high.
  """

  use Minga.Test.EditorCase, async: true

  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Keymap.Active, as: KeymapActive
  alias MingaEditor
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Window
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
    events_registry = :"agent_cursor_events_#{id}"
    {:ok, _events} = Registry.start_link(keys: :duplicate, name: events_registry)
    {:ok, options_server} = Options.start_link(name: nil)
    {:ok, _} = Options.set(options_server, :clipboard, :none)
    {:ok, keymap_server} = KeymapActive.start_link(name: nil)

    {:ok, port} = HeadlessPort.start_link(width: width, height: height)

    agent_buf = AgentBufferSync.start_buffer()
    assert is_pid(agent_buf), "Failed to start agent buffer"

    {:ok, file_buf} =
      BufferProcess.start_link(
        content: "",
        buffer_name: "unnamed",
        events_registry: events_registry
      )

    BufferProcess.set_option(file_buf, :clipboard, :none)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"headless_agent_cursor_#{id}",
        port_manager: port,
        buffer: file_buf,
        width: width,
        height: height,
        editing_model: :vim,
        events_registry: events_registry,
        keymap_server: keymap_server,
        options_server: options_server
      )

    {:ok, fake_session} = StubServer.start_link()

    :sys.replace_state(editor, fn state ->
      win_id = state.workspace.windows.active
      agent_window = Window.new_agent_chat(win_id, agent_buf, height, width)

      windows = %{
        state.workspace.windows
        | map: Map.put(state.workspace.windows.map, win_id, agent_window)
      }

      agent_tab_bar = TabBar.new(Tab.new_agent(1, "Agent"))

      agent_state =
        state.shell_state.agent
        |> Map.put(:buffer, agent_buf)
        |> Map.put(:session, fake_session)

      ss = state.shell_state

      %{
        state
        | workspace: %{state.workspace | windows: windows, keymap_scope: :agent},
          shell_state: %{ss | tab_bar: agent_tab_bar, agent: agent_state}
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

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "agent prompt cursor positioning" do
    test "cursor starts and stays on the input content row" do
      ctx = start_agent_editor()

      send_keys_sync(ctx, "i")

      rows = screen_text(ctx)
      {cursor_row, _cursor_col} = screen_cursor(ctx)
      border_row = find_row_containing(rows, "Prompt")
      content_row = find_row_containing(rows, "Type a message")

      assert border_row != nil, "Should find the Prompt border row on screen"
      assert content_row != nil, "Should find the input content row on screen"
      assert border_row < content_row, "Border should be above the content row"
      assert cursor_row == content_row

      type_text(ctx, "hello")
      sync_screen(ctx)

      rows = screen_text(ctx)
      {cursor_row, _cursor_col} = screen_cursor(ctx)
      typed_row = find_row_containing(rows, "hello")

      assert typed_row != nil, "Should find typed text on screen"
      assert cursor_row == typed_row
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
end
