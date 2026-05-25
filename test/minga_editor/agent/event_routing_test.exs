defmodule MingaEditor.Agent.EventRoutingTest do
  @moduledoc """
  Verifies the foreground/background split for agent events.

  The runtime split lives in `MingaEditor.handle_info/2` for `:agent_event`
  messages: events whose `session_pid` matches `AgentAccess.session/1` go
  through `Agent.Events.handle/2` (rendering cache + tab status); the
  rest go through `Shell.on_agent_event/4` (presentation only — never
  the active tab's rendering cache).

  These tests pin the shell callbacks directly so the routing contract
  is exercised without booting the editor GenServer.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.Agent.Events
  alias MingaEditor.Agent.UIState
  alias MingaAgent.Event
  alias MingaAgent.Session
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Session.State, as: SessionState

  defp workspace, do: %SessionState{viewport: Viewport.new(24, 80), editing: VimState.new()}

  defp fake_session_pid do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end

  defp tab(%TabBar{tabs: tabs}, id), do: Enum.find(tabs, &(&1.id == id))

  defp tab_bar(tabs, active_id) do
    [first | rest] = tabs
    tb = TabBar.new(first)

    tb =
      Enum.reduce(rest, tb, fn tab, acc ->
        %{acc | tabs: acc.tabs ++ [tab], next_id: max(acc.next_id, tab.id + 1)}
      end)

    %{tb | active_id: active_id}
  end

  # ── Traditional shell ──────────────────────────────────────────────────

  describe "Traditional.on_agent_event/4" do
    setup do
      session_a = fake_session_pid()
      session_b = fake_session_pid()

      tabs = [
        Tab.new_agent(1, "A") |> Tab.set_session(session_a),
        Tab.new_agent(2, "B") |> Tab.set_session(session_b)
      ]

      shell_state = %TraditionalState{
        agent: %AgentState{},
        tab_bar: tab_bar(tabs, 1)
      }

      %{shell_state: shell_state, session_a: session_a, session_b: session_b}
    end

    test "background :status_changed event sets the owning tab's badge without touching the active rendering cache",
         %{shell_state: ss, session_b: session_b} do
      {ss2, ws2, effects} =
        Traditional.on_agent_event(ss, workspace(), session_b, {:status_changed, :thinking})

      # Background tab's badge updates...
      assert tab(ss2.tab_bar, 2).agent_status == :thinking

      # ...but the active rendering cache is untouched (it routes through
      # Agent.Events for the foreground path, not through this callback).
      assert ss2.agent == ss.agent

      # Workspace is also untouched: background events must not nudge the
      # active tab's editing surface.
      assert ws2 == workspace()
      assert effects == []
    end

    test "background :status_changed -> :idle raises attention on the owning tab", %{
      shell_state: ss,
      session_b: session_b
    } do
      {ss2, _ws, _effects} =
        Traditional.on_agent_event(ss, workspace(), session_b, {:status_changed, :idle})

      assert tab(ss2.tab_bar, 2).attention == true
      assert tab(ss2.tab_bar, 1).attention == false
    end

    test "background :approval_pending raises attention on the owning tab", %{
      shell_state: ss,
      session_b: session_b
    } do
      approval = %{tool_call_id: "x", name: "shell", args: %{}}

      {ss2, _ws, _effects} =
        Traditional.on_agent_event(ss, workspace(), session_b, {:approval_pending, approval})

      assert tab(ss2.tab_bar, 2).attention == true
      assert tab(ss2.tab_bar, 1).attention == false
    end

    test "background :error raises attention on the owning tab", %{
      shell_state: ss,
      session_b: session_b
    } do
      {ss2, _ws, _effects} =
        Traditional.on_agent_event(ss, workspace(), session_b, {:error, "boom"})

      assert tab(ss2.tab_bar, 2).attention == true
      assert tab(ss2.tab_bar, 1).attention == false
    end

    test "background :text_delta does not mutate state at all", %{
      shell_state: ss,
      session_b: session_b
    } do
      # Streaming text from a background session must not reach this callback's
      # mutation path — the delta is purely a no-op so the active tab's UI
      # never re-renders for unrelated streaming.
      {ss2, ws2, effects} =
        Traditional.on_agent_event(ss, workspace(), session_b, {:text_delta, "hello"})

      assert ss2 == ss
      assert ws2 == workspace()
      assert effects == []
    end

    test "events from a session that no longer maps to any tab are silently dropped", %{
      shell_state: ss
    } do
      ghost = spawn(fn -> :ok end)

      {ss2, _ws, _effects} =
        Traditional.on_agent_event(ss, workspace(), ghost, {:status_changed, :error})

      assert ss2.tab_bar == ss.tab_bar
    end
  end

  describe "Agent.Events.handle/2 tool status" do
    test "tool_started and tool_ended keep active_tool_name synced with the session snapshot" do
      {:ok, session} = start_supervised({Session, provider_opts: []})
      :sys.get_state(session)

      {tab_bar, workspace} =
        TabBar.add_workspace(TabBar.new(Tab.new_agent(1, "Agent")), "Agent", session)

      tab_bar = TabBar.move_tab_to_workspace(tab_bar, 1, workspace.id)

      state = %{
        agent: %AgentState{},
        shell: Traditional,
        shell_state: %{tab_bar: tab_bar}
      }

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "alpha", args: %{}}}
      )

      :sys.get_state(session)
      {state, effects} = Events.handle(state, {:tool_started, "alpha", %{}})
      assert AgentState.active_tool_name(state.agent) == "alpha"
      assert effects == [{:render, 16}]

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc2", name: "beta", args: %{}}}
      )

      :sys.get_state(session)
      {state, effects} = Events.handle(state, {:tool_started, "beta", %{}})
      assert AgentState.active_tool_name(state.agent) == "beta"
      assert effects == [{:render, 16}]

      send(
        session,
        {:agent_provider_event,
         %Event.ToolEnd{tool_call_id: "tc1", name: "alpha", result: "contents"}}
      )

      :sys.get_state(session)
      {state, effects} = Events.handle(state, {:tool_ended, "alpha", "contents", :done})
      assert AgentState.active_tool_name(state.agent) == "beta"
      assert effects == [{:render, 16}]

      send(
        session,
        {:agent_provider_event,
         %Event.ToolEnd{tool_call_id: "tc2", name: "beta", result: "output"}}
      )

      :sys.get_state(session)
      {state, effects} = Events.handle(state, {:tool_ended, "beta", "output", :done})
      assert AgentState.active_tool_name(state.agent) == nil
      assert effects == [{:render, 16}]
    end

    test "tool_started and tool_ended fall back for map states without a session" do
      state = %{agent: %AgentState{}, agent_ui: UIState.new()}

      {state, effects} = Events.handle(state, {:tool_started, "read_file", %{}})
      assert AgentState.active_tool_name(state.agent) == "read_file"
      assert effects == [{:render, 16}]

      {state, effects} = Events.handle(state, {:tool_ended, "read_file", "contents", :done})
      assert AgentState.active_tool_name(state.agent) == nil
      assert effects == [{:render, 16}]
    end

    test "status_changed clears active_tool_name outside tool execution" do
      state = %{agent: %AgentState{} |> AgentState.set_active_tool_name("read_file")}

      {state, _effects} = Events.handle(state, {:status_changed, :tool_executing})
      assert AgentState.active_tool_name(state.agent) == "read_file"

      {state, effects} = Events.handle(state, {:status_changed, :idle})
      assert AgentState.active_tool_name(state.agent) == nil
      assert effects == [:render]
    end
  end

  describe "Agent.Events.handle/2 file association" do
    test "file_changed associates by exact file ref, not duplicate basename" do
      root = Path.join(System.tmp_dir!(), "minga-event-routing")
      lib_path = Path.join([root, "lib", "user.ex"])
      test_path = Path.join([root, "test", "user.ex"])
      assert {:ok, lib_ref} = FileRef.from_path(root, lib_path)
      assert {:ok, test_ref} = FileRef.from_path(root, test_path)

      session = fake_session_pid()
      tab1 = Tab.new_file(1, "user.ex") |> Tab.set_file_ref(lib_ref)
      tab2 = Tab.new_file(2, "user.ex") |> Tab.set_file_ref(test_ref)
      agent_tab = Tab.new_agent(3, "Agent") |> Tab.set_session(session)

      tb = TabBar.new(tab1, root)
      tb = %{tb | tabs: [tab1, tab2, agent_tab], active_id: 3, next_id: 4}
      {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
      tb = TabBar.move_tab_to_workspace(tb, agent_tab.id, workspace.id)

      state = %EditorState{
        port_manager: self(),
        shell: Traditional,
        workspace:
          %SessionState{viewport: Viewport.new(24, 80)}
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_state: %TraditionalState{agent: %AgentState{}, tab_bar: tb}
      }

      {state, _effects} =
        Events.handle(
          state,
          {:file_changed, test_path, "before", "after", "tc_test", "edit_file"}
        )

      tb = state.shell_state.tab_bar
      assert TabBar.get(tb, tab1.id).group_id == 0
      assert TabBar.get(tb, tab2.id).group_id == workspace.id
      assert Workspace.has_file?(TabBar.get_workspace(tb, workspace.id), test_ref)
      refute Workspace.has_file?(TabBar.get_workspace(tb, workspace.id), lib_ref)
    end

    test "file_changed keeps an existing active file when associating a background file" do
      root = Path.join(System.tmp_dir!(), "minga-event-routing-active-file")
      lib_path = Path.join([root, "lib", "user.ex"])
      test_path = Path.join([root, "test", "user.ex"])
      active_path = Path.join([root, "lib", "active.ex"])
      assert {:ok, lib_ref} = FileRef.from_path(root, lib_path)
      assert {:ok, test_ref} = FileRef.from_path(root, test_path)
      assert {:ok, active_ref} = FileRef.from_path(root, active_path)

      session = fake_session_pid()
      tab1 = Tab.new_file(1, "user.ex") |> Tab.set_file_ref(lib_ref)
      tab2 = Tab.new_file(2, "user.ex") |> Tab.set_file_ref(test_ref)
      agent_tab = Tab.new_agent(3, "Agent") |> Tab.set_session(session)

      tb = TabBar.new(tab1, root)
      tb = %{tb | tabs: [tab1, tab2, agent_tab], active_id: 3, next_id: 4}
      {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
      tb = TabBar.move_tab_to_workspace(tb, agent_tab.id, workspace.id)

      tb =
        TabBar.update_workspace(tb, workspace.id, fn ws ->
          ws
          |> Workspace.add_file(active_ref)
          |> Workspace.set_active_file(active_ref)
        end)

      state = %EditorState{
        port_manager: self(),
        shell: Traditional,
        workspace:
          %SessionState{viewport: Viewport.new(24, 80)}
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_state: %TraditionalState{agent: %AgentState{}, tab_bar: tb}
      }

      {state, _effects} =
        Events.handle(
          state,
          {:file_changed, test_path, "before", "after", "tc_test", "edit_file"}
        )

      tb = state.shell_state.tab_bar
      agent_workspace = TabBar.get_workspace(tb, workspace.id)
      assert TabBar.get(tb, tab2.id).group_id == workspace.id
      assert Workspace.has_file?(agent_workspace, test_ref)
      assert Workspace.has_file?(agent_workspace, active_ref)
      assert agent_workspace.active_file == active_ref
    end

    test "file_changed derives missing tab file ref from snapshotted buffer context" do
      root = Path.join(System.tmp_dir!(), "minga-event-routing")
      path = Path.join([root, "lib", "initial.ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "before")
      {:ok, buffer} = start_supervised({BufferProcess, content: "before", file_path: path})
      assert {:ok, expected_ref} = FileRef.from_path(root, path)

      session = fake_session_pid()

      file_tab =
        Tab.new_file(1, "initial.ex")
        |> Tab.set_context(%{buffers: %Buffers{active: buffer, list: [buffer], active_index: 0}})

      agent_tab = Tab.new_agent(2, "Agent") |> Tab.set_session(session)

      tb = TabBar.new(file_tab, root)
      tb = %{tb | tabs: [file_tab, agent_tab], active_id: 2, next_id: 3}
      {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
      tb = TabBar.move_tab_to_workspace(tb, agent_tab.id, workspace.id)

      state = %EditorState{
        port_manager: self(),
        shell: Traditional,
        workspace:
          %SessionState{viewport: Viewport.new(24, 80)}
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_state: %TraditionalState{agent: %AgentState{}, tab_bar: tb}
      }

      {state, _effects} =
        Events.handle(state, {:file_changed, path, "before", "after", "tc_test", "edit_file"})

      tb = state.shell_state.tab_bar
      assert TabBar.get(tb, file_tab.id).group_id == workspace.id
      assert Workspace.has_file?(TabBar.get_workspace(tb, workspace.id), expected_ref)
    end

    test "file_changed outside the project root leaves workspace associations untouched" do
      root = Path.join(System.tmp_dir!(), "minga-event-routing-root")
      path = Path.join(System.tmp_dir!(), "minga-event-routing-outside.ex")
      session = fake_session_pid()

      file_tab = Tab.new_file(1, "initial.ex")
      agent_tab = Tab.new_agent(2, "Agent") |> Tab.set_session(session)

      tb = TabBar.new(file_tab, root)
      tb = %{tb | tabs: [file_tab, agent_tab], active_id: 2, next_id: 3}
      {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
      tb = TabBar.move_tab_to_workspace(tb, agent_tab.id, workspace.id)

      state = %EditorState{
        port_manager: self(),
        shell: Traditional,
        workspace:
          %SessionState{viewport: Viewport.new(24, 80)}
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_state: %TraditionalState{agent: %AgentState{}, tab_bar: tb}
      }

      {state, _effects} =
        Events.handle(state, {:file_changed, path, "before", "after", "tc_test", "edit_file"})

      tb = state.shell_state.tab_bar
      assert TabBar.get(tb, file_tab.id).group_id == 0
      assert TabBar.get(tb, agent_tab.id).group_id == workspace.id
      assert TabBar.get_workspace(tb, workspace.id).files == []
    end
  end
end
