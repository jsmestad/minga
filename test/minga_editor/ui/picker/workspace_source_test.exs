defmodule MingaEditor.UI.Picker.WorkspaceSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Mode
  alias MingaAgent.Question
  alias MingaAgent.Question.Target, as: QuestionTarget
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.WorkspaceSource
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  defp fake_context(tab_bar) do
    %Context{
      buffers: %Buffers{list: [], active: nil, active_index: 0},
      editing: VimState.new(),
      file_tree: nil,
      search: %Search{},
      viewport: Viewport.new(80, 24),
      tab_bar: tab_bar,
      agent_session: nil,
      picker_ui: %{},
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end

  defp editor_state(tab_bar, buffer, mode) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %MingaEditor.Session.State{
        editing: %VimState{mode: mode, mode_state: Mode.initial_state()},
        buffers: %Buffers{list: [buffer], active: buffer, active_index: 0},
        keymap_scope: :editor
      },
      shell_runtime: Runtime.new(Runtime.default_entry(), %ShellState{tab_bar: tab_bar})
    }
  end

  describe "candidates/1" do
    test "returns one item per workspace with tabs, including manual" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_workspace(tb, "Research")
      tb = TabBar.move_tab_to_workspace(tb, 2, group.id)

      items = WorkspaceSource.candidates(fake_context(tb))
      assert Enum.map(items, & &1.id) == [0, group.id]
    end

    test "filters out agent workspaces with no tabs" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add_workspace(tb, "Empty")

      items = WorkspaceSource.candidates(fake_context(tb))
      assert Enum.map(items, & &1.id) == [0]
    end

    test "shows file names in description" do
      tb = TabBar.new(Tab.new_file(1, "editor.ex"))
      {tb, _} = TabBar.add(tb, :file, "main.ex")
      {tb, group} = TabBar.add_workspace(tb, "Work")
      tb = TabBar.move_tab_to_workspace(tb, 1, group.id)
      tb = TabBar.move_tab_to_workspace(tb, 2, group.id)

      [item] = WorkspaceSource.candidates(fake_context(tb))
      assert item.description =~ "editor.ex"
      assert item.description =~ "main.ex"
    end

    test "returns empty for context without TabBar struct" do
      ctx = %Context{
        buffers: %Buffers{list: [], active: nil, active_index: 0},
        editing: VimState.new(),
        file_tree: nil,
        search: %Search{},
        viewport: Viewport.new(80, 24),
        tab_bar: %{},
        agent_session: nil,
        picker_ui: %{},
        capabilities: %{},
        theme: Theme.get!(:doom_one)
      }

      assert WorkspaceSource.candidates(ctx) == []
    end
  end

  describe "Agent status rows" do
    # The active Agent workspace takes its status from the live Agent state
    # (WorkspaceStatus); a background workspace keeps its stored status.
    setup do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, active_tab} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_workspace(tb, "Agent", self())
      tb = TabBar.move_tab_to_workspace(tb, active_tab.id, group.id)
      tb = TabBar.set_workspace_agent_status(tb, group.id, :idle)
      tb = TabBar.switch_to_workspace(tb, group.id)

      {:ok, tb: tb, group: group}
    end

    defp status_row(ctx, group_id) do
      Enum.find(WorkspaceSource.candidates(ctx), &(&1.id == group_id))
    end

    test "active workspace shows a pending question from the live Agent state", %{
      tb: tb,
      group: group
    } do
      {:ok, question} = Question.new("Which file?", ["a.ex", "b.ex"])

      target = %QuestionTarget{
        session_id: "picker-fixture",
        request_id: "request",
        checkpoint_id: "checkpoint",
        tool_call_id: "tool-call"
      }

      live = AgentState.project_question(%AgentState{}, self(), {target, question})
      ctx = %{fake_context(tb) | live_agent: live, live_agent_ui: UIState.new()}

      row = status_row(ctx, group.id)
      assert row.annotation == "! needs you"
      assert row.description =~ "! needs you"
    end

    test "active workspace shows a live error over its stale stored status", %{
      tb: tb,
      group: group
    } do
      live = AgentState.set_status(%AgentState{}, :error)
      ctx = %{fake_context(tb) | live_agent: live, live_agent_ui: UIState.new()}

      row = status_row(ctx, group.id)
      assert row.annotation == "⚠ error"
      assert row.description =~ "⚠ error"
    end

    test "active workspace with a failed start needs you", %{tb: tb, group: group} do
      failed_ui =
        UIState.fail_start(UIState.new(), StartFailure.timed_out(StartRequest.default()))

      ctx = %{fake_context(tb) | live_agent: nil, live_agent_ui: failed_ui}

      row = status_row(ctx, group.id)
      assert row.annotation == "! needs you"
    end

    test "background workspace keeps its stored status even when a live cache is set", %{
      tb: tb,
      group: group
    } do
      tb = TabBar.set_workspace_agent_status(tb, group.id, :thinking)
      tb = TabBar.switch_to_workspace(tb, 0)
      live = AgentState.set_status(%AgentState{}, :error)
      ctx = %{fake_context(tb) | live_agent: live, live_agent_ui: UIState.new()}

      row = status_row(ctx, group.id)
      assert row.annotation == "↻ thinking"
      assert row.description =~ "↻ thinking"
    end

    test "background workspace with a failed start needs you from its stored UI", %{
      tb: tb,
      group: group
    } do
      failed_ui =
        UIState.fail_start(UIState.new(), StartFailure.timed_out(StartRequest.default()))

      tb = TabBar.set_workspace_agent_ui(tb, group.id, failed_ui)
      tb = TabBar.switch_to_workspace(tb, 0)
      ctx = %{fake_context(tb) | live_agent: nil, live_agent_ui: UIState.new()}

      row = status_row(ctx, group.id)
      assert row.annotation == "! needs you"
    end
  end

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content},
      id: {:workspace_source_buffer, :erlang.unique_integer([:positive])}
    )
  end

  describe "on_select/2" do
    test "switches through the editor path and restores the selected workspace" do
      buf_a = start_buffer("a")
      buf_b = start_buffer("b")

      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, tab2} = TabBar.add(tb, :file, "b.ex")
      {tb, group} = TabBar.add_workspace(tb, "Agent")
      tb = TabBar.move_tab_to_workspace(tb, tab2.id, group.id)
      tb = TabBar.switch_to(tb, 1)

      target_context =
        editor_state(nil, buf_b, :insert)
        |> then(&MingaEditor.State.Tab.Context.snapshot(&1.workspace))

      tb = TabBar.update_context(tb, tab2.id, target_context)
      state = editor_state(tb, buf_a, :normal)

      switched = WorkspaceSource.on_select(%Item{id: group.id, label: "Agent"}, state)

      assert switched.workspace.buffers.active == buf_b
      assert switched.workspace.editing.mode == :insert
      assert switched.shell_runtime.state.tab_bar.active_id == tab2.id
      assert MingaEditor.Shell.Runtime.active_tab(switched.shell_runtime).id == tab2.id
      assert TabBar.get(switched.shell_runtime.state.tab_bar, 1).context.buffers.active == buf_a

      assert TabBar.get(switched.shell_runtime.state.tab_bar, tab2.id).context.buffers.active ==
               buf_b
    end

    test "selecting workspace with no visible target is unchanged" do
      state = editor_state(TabBar.new_empty(), start_buffer("a"), :normal)

      assert WorkspaceSource.on_select(%Item{id: 0, label: "Manual"}, state) == state
    end
  end
end
