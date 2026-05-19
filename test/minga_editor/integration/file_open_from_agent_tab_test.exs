defmodule Minga.Integration.FileOpenFromAgentTabTest do
  @moduledoc """
  Regression smoke test for opening a file while the agent tab is active.

  The detailed tab/window invariants are owned by lower-level state tests. This file proves the user-visible contract: opening from the agent tab shows the file, restores normal editor chrome, and routes following keys to the file buffer.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor
  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Workspace.State, as: WorkspaceState
  alias MingaEditor.Window
  alias Minga.Test.HeadlessPort
  alias Minga.Test.StubServer

  @moduletag :tmp_dir

  @spec start_editor_in_agent_mode(keyword()) :: map()
  defp start_editor_in_agent_mode(opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    id = :erlang.unique_integer([:positive])

    {:ok, port} = HeadlessPort.start_link(width: width, height: height)
    agent_buf = AgentBufferSync.start_buffer()
    assert is_pid(agent_buf), "Failed to start agent buffer"

    {:ok, file_buf} = BufferProcess.start_link(content: "", buffer_name: "unnamed")

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"headless_agent_editor_#{id}",
        port_manager: port,
        buffer: file_buf,
        width: width,
        height: height,
        editing_model: :vim
      )

    {:ok, fake_session} = StubServer.start_link()

    :sys.replace_state(editor, fn state ->
      win_id = state.workspace.windows.active
      agent_window = Window.new_agent_chat(win_id, agent_buf, height, width)

      windows = %{
        state.workspace.windows
        | map: Map.put(state.workspace.windows.map, win_id, agent_window)
      }

      manual_tab =
        Tab.new_file(1, "unnamed")
        |> Tab.set_context(WorkspaceState.to_tab_context(state.workspace))

      agent_tab_bar = TabBar.new(manual_tab)
      {agent_tab_bar, agent_tab} = TabBar.add(agent_tab_bar, :agent, "Agent")
      {agent_tab_bar, group} = TabBar.add_agent_group(agent_tab_bar, "Agent")
      agent_tab_bar = TabBar.move_tab_to_group(agent_tab_bar, agent_tab.id, group.id)

      agent_state =
        state.shell_state.agent
        |> Map.put(:buffer, agent_buf)
        |> Map.put(:session, fake_session)

      ss = state.shell_state

      %{
        state
        | workspace: %{state.workspace | windows: windows, keymap_scope: :agent},
          shell_state: %{
            ss
            | tab_bar: agent_tab_bar,
              agent: agent_state,
              suppress_tool_prompts: true
          }
      }
    end)

    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    {:ok, snapshot} = HeadlessPort.collect_frame(ref, 15_000)
    Process.put({:last_frame_snapshot, port}, snapshot)

    %{
      editor: editor,
      buffer: file_buf,
      agent_buffer: agent_buf,
      port: port,
      width: width,
      height: height
    }
  end

  defp open_file_and_wait(ctx, file_path) do
    ref = HeadlessPort.prepare_await(ctx.port)
    :ok = MingaEditor.open_file(ctx.editor, file_path)
    {:ok, snapshot} = HeadlessPort.collect_frame(ref, 15_000)
    Process.put({:last_frame_snapshot, ctx.port}, snapshot)
    :ok
  end

  describe "opening a file from the agent tab" do
    test "restores the visible file editing surface", %{tmp_dir: tmp_dir} do
      ctx = start_editor_in_agent_mode()
      file_path = Path.join(tmp_dir, ".credo.exs")
      File.write!(file_path, "configs = [:editor]\n")

      open_file_and_wait(ctx, file_path)

      wait_until_screen(ctx, fn -> String.contains?(screen_row(ctx, 0), ".credo.exs") end,
        message: "Expected opened file tab to become visible"
      )

      assert String.contains?(screen_row(ctx, 0), ".credo.exs")
      assert screen_contains?(ctx, "configs = [:editor]")
      assert_modeline_contains(ctx, "NORMAL")
      refute String.contains?(modeline(ctx), "Prompt")

      send_keys_sync(ctx, "i# <Esc>")

      assert screen_contains?(ctx, "# configs = [:editor]")
    end

    test "opens the same path as separate file tabs in different workspaces", %{tmp_dir: tmp_dir} do
      ctx = start_editor_in_agent_mode()
      file_path = Path.join(tmp_dir, "shared.ex")
      File.write!(file_path, "value = :shared\n")

      open_file_and_wait(ctx, file_path)

      agent_state = :sys.get_state(ctx.editor)
      agent_workspace_id = TabBar.active_group_id(agent_state.shell_state.tab_bar)
      agent_file_tabs = TabBar.visible_file_tabs(agent_state.shell_state.tab_bar)
      assert Enum.map(agent_file_tabs, & &1.group_id) == [agent_workspace_id]

      :sys.replace_state(ctx.editor, &EditorState.switch_tab(&1, 1))
      open_file_and_wait(ctx, file_path)

      state = :sys.get_state(ctx.editor)
      manual_tabs = TabBar.visible_file_tabs(state.shell_state.tab_bar, 0)
      agent_tabs = TabBar.visible_file_tabs(state.shell_state.tab_bar, agent_workspace_id)

      assert length(manual_tabs) == 2
      assert length(agent_tabs) == 1
      assert Enum.map(manual_tabs ++ agent_tabs, & &1.id) |> Enum.uniq() |> length() == 3

      :ok = MingaEditor.open_file(ctx.editor, file_path)
      reopened_state = :sys.get_state(ctx.editor)

      assert length(TabBar.visible_file_tabs(reopened_state.shell_state.tab_bar, 0)) == 2
      assert TabBar.active_group_id(reopened_state.shell_state.tab_bar) == 0
    end
  end
end
