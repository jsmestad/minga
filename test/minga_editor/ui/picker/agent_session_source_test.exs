defmodule MingaEditor.UI.Picker.AgentSessionSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaAgent.Session
  alias MingaAgent.SessionStore
  alias MingaAgent.Subagent.Handle
  alias MingaAgent.TurnUsage
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.RuntimeState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.UI.Picker.AgentSessionSource

  @moduletag :tmp_dir

  describe "title/0" do
    test "returns Sessions" do
      assert AgentSessionSource.title() == "Sessions"
    end
  end

  describe "preview?/0" do
    test "returns false" do
      refute AgentSessionSource.preview?()
    end
  end

  describe "candidates/1" do
    test "returns only disk candidates when no agent tabs" do
      tb = TabBar.new(Tab.new_file(1, "main.ex"))

      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{},
          windows: %Windows{},
          editing: VimState.new()
        },
        shell_state: %MingaEditor.Shell.Traditional.State{
          tab_bar: tb,
          agent: %AgentState{}
        }
      }

      ctx = Context.from_editor_state(state)
      candidates = AgentSessionSource.candidates(ctx)

      Enum.each(candidates, fn %Item{id: {_, tag}} ->
        assert tag == :disk
      end)
    end

    test "returns tab candidates when agent tabs exist" do
      {:ok, pid} = start_test_session()
      Session.subscribe(pid)

      state = state_with_agent_tab(pid)
      ctx = Context.from_editor_state(state)
      candidates = AgentSessionSource.candidates(ctx)
      tab_entries = Enum.filter(candidates, fn %Item{id: {_, tag}} -> match?({:tab, _}, tag) end)
      assert tab_entries != []

      %Item{id: {_, {:tab, _tab_id}}, label: label, description: desc} = hd(tab_entries)
      assert is_binary(label)
      assert String.contains?(desc, "test-model")

      Session.unsubscribe(pid)
      stop_session(pid)
    end

    test "active agent tab is marked with bullet" do
      {:ok, pid} = start_test_session()
      Session.subscribe(pid)

      state = state_with_agent_tab(pid)
      ctx = Context.from_editor_state(state)
      candidates = AgentSessionSource.candidates(ctx)

      active =
        Enum.find(candidates, fn
          %Item{id: {_, {:tab, _}}, label: label} -> String.contains?(label, "\u{2022}")
          _ -> false
        end)

      assert active != nil

      Session.unsubscribe(pid)
      stop_session(pid)
    end

    test "candidates include completed and failed background subagent tabs" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()
      Session.subscribe(pid1)
      Session.subscribe(pid2)

      state =
        state_with_two_agent_tabs(pid1, pid2)
        |> mark_all_agent_tabs_as_background([:idle, :error])

      ctx = Context.from_editor_state(state)
      candidates = AgentSessionSource.candidates(ctx)

      tab_entries = Enum.filter(candidates, fn %Item{id: {_, tag}} -> match?({:tab, _}, tag) end)
      assert length(tab_entries) >= 2

      target =
        Enum.find(tab_entries, fn %Item{id: {_, {:tab, id}}} ->
          id != state.shell_state.tab_bar.active_id
        end)

      result = AgentSessionSource.on_select(target, state)
      assert result.shell_state.tab_bar.active_id == elem(elem(target.id, 1), 1)

      Session.unsubscribe(pid1)
      Session.unsubscribe(pid2)
      stop_session(pid1)
      stop_session(pid2)
    end

    test "disk candidates show title, last timestamp, turn count, and most-recent-first order", %{
      tmp_dir: dir
    } do
      save_disk_session(dir, "old", "Old planning", "2026-01-01T00:00:00Z", [
        {:user, "Old planning"}
      ])

      save_disk_session(dir, "new", "New architecture", "2026-01-03T00:00:00Z", [
        {:user, "New architecture"},
        {:assistant, "Latest notes"}
      ])

      save_disk_session(dir, "middle", "Middle refactor", "2026-01-02T00:00:00Z", [
        {:user, "Middle refactor"}
      ])

      ctx = Context.from_editor_state(state_without_agent_tabs(), %{session_store_dir: dir})
      candidates = AgentSessionSource.candidates(ctx)
      disk_entries = Enum.filter(candidates, fn %Item{id: {_, tag}} -> tag == :disk end)

      assert Enum.map(disk_entries, fn %Item{id: {id, :disk}} -> id end) == [
               "new",
               "middle",
               "old"
             ]

      assert [%Item{label: "New architecture", description: desc, annotation: "1 turn"} | _] =
               disk_entries

      assert desc =~ "Jan 03 00:00"
      assert desc =~ "Latest notes"
    end

    test "disk candidates filter by title and recent message content", %{tmp_dir: dir} do
      save_disk_session(dir, "auth", "Auth refactor", "2026-01-01T00:00:00Z", [
        {:user, "Auth refactor"}
      ])

      save_disk_session(dir, "backoff", "Retry work", "2026-01-02T00:00:00Z", [
        {:user, "Investigate client"},
        {:assistant, "Use rate limit backoff"}
      ])

      ctx = Context.from_editor_state(state_without_agent_tabs(), %{session_store_dir: dir})
      candidates = AgentSessionSource.candidates(ctx)

      auth_picker =
        Picker.new(candidates, title: AgentSessionSource.title()) |> Picker.filter("auth")

      backoff_picker =
        Picker.new(candidates, title: AgentSessionSource.title()) |> Picker.filter("backoff")

      assert Enum.map(auth_picker.filtered, fn %Item{id: {id, :disk}} -> id end) == ["auth"]
      assert Enum.map(backoff_picker.filtered, fn %Item{id: {id, :disk}} -> id end) == ["backoff"]
    end

    test "background agent tab is not marked with bullet" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()
      Session.subscribe(pid1)
      Session.subscribe(pid2)

      state = state_with_two_agent_tabs(pid1, pid2)
      ctx = Context.from_editor_state(state)
      candidates = AgentSessionSource.candidates(ctx)

      # Active tab is the first one (pid1). Background tab (pid2) should not have bullet.
      bg_tabs =
        Enum.filter(candidates, fn
          %Item{id: {_, {:tab, id}}} -> id != state.shell_state.tab_bar.active_id
          _ -> false
        end)

      assert bg_tabs != []

      Enum.each(bg_tabs, fn %Item{label: label} ->
        refute String.contains?(label, "\u{2022}")
      end)

      Session.unsubscribe(pid1)
      Session.unsubscribe(pid2)
      stop_session(pid1)
      stop_session(pid2)
    end
  end

  describe "on_select/2" do
    test "with disk entry restores the active session through the public session path", %{
      tmp_dir: dir
    } do
      {:ok, pid} = start_test_session(session_store_dir: dir)

      save_disk_session(dir, "saved-disk", "Saved session", "2026-01-01T00:00:00Z", [
        {:user, "Saved session"},
        {:assistant, "Loaded response"}
      ])

      state = state_with_agent_tab(pid)
      item = %Item{id: {"saved-disk", :disk}, label: "Saved session", description: "desc"}
      _result = AgentSessionSource.on_select(item, state)

      assert Session.session_id(pid) == "saved-disk"
      assert Session.messages(pid) == [{:user, "Saved session"}, {:assistant, "Loaded response"}]

      stop_session(pid)
    end

    test "with tab entry switches to that tab" do
      {:ok, pid} = start_test_session()
      Session.subscribe(pid)

      state = state_with_two_tabs_file_active(pid)
      agent_tab_id = Enum.find(state.shell_state.tab_bar.tabs, &(&1.kind == :agent)).id
      item = %Item{id: {"some-id", {:tab, agent_tab_id}}, label: "label", description: "desc"}
      result = AgentSessionSource.on_select(item, state)
      assert result.shell_state.tab_bar.active_id == agent_tab_id

      Session.unsubscribe(pid)
      stop_session(pid)
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{agent: %AgentState{}}
      assert AgentSessionSource.on_cancel(state) == state
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp save_disk_session(dir, id, title, last_message_at, messages) do
    SessionStore.save(
      %{
        id: id,
        timestamp: "2026-01-01T00:00:00Z",
        last_message_at: last_message_at,
        title: title,
        model_name: "test-model",
        provider_name: "native",
        messages: messages,
        usage: %TurnUsage{}
      },
      dir
    )
  end

  defp state_without_agent_tabs do
    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{},
        windows: %Windows{},
        editing: VimState.new()
      },
      shell_state: %MingaEditor.Shell.Traditional.State{
        tab_bar: TabBar.new(Tab.new_file(1, "main.ex")),
        agent: %AgentState{}
      }
    }
  end

  defp start_test_session(opts \\ []) do
    MingaAgent.Supervisor.start_session(
      provider: MingaAgent.Providers.Native,
      model_name: "test-model",
      session_store_dir: Keyword.get(opts, :session_store_dir),
      provider_opts: [
        llm_client: fn _req -> {:ok, %{status: 200, body: %{"choices" => []}}} end
      ]
    )
  end

  defp stop_session(pid) do
    MingaAgent.Supervisor.stop_session(pid)
  end

  defp mark_all_agent_tabs_as_background(state, statuses) do
    {tabs, _idx} =
      Enum.map_reduce(state.shell_state.tab_bar.tabs, 0, fn
        %Tab{kind: :agent, session: session} = tab, idx ->
          status = Enum.at(statuses, idx, :idle)

          handle =
            Handle.new(
              session_id: "session-#{idx + 1}",
              pid: session,
              task: "background #{idx + 1}"
            )

          tab =
            tab
            |> Tab.set_agent_status(status)
            |> Tab.mark_background_subagent(handle)

          {tab, idx + 1}

        tab, idx ->
          {tab, idx}
      end)

    put_in(state.shell_state.tab_bar.tabs, tabs)
  end

  defp state_with_agent_tab(session_pid) do
    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent 1")
    tb = TabBar.update_tab(tb, agent_tab.id, &Tab.set_session(&1, session_pid))
    # Make the agent tab active
    tb = TabBar.switch_to(tb, agent_tab.id)

    agent_ctx = %{
      shell_state: %MingaEditor.Shell.Traditional.State{
        agent: %AgentState{runtime: %RuntimeState{status: :idle}}
      },
      agent_ui: %UIState{view: %UIState.View{active: true, focus: :chat}},
      windows: %Windows{},
      file_tree: nil,
      editing: VimState.new(),
      keymap_scope: :agent,
      active_buffer: nil,
      active_buffer_index: 0
    }

    tb = TabBar.update_context(tb, agent_tab.id, agent_ctx)

    agent = %AgentState{runtime: %RuntimeState{status: :idle}}
    agentic = %UIState{view: %UIState.View{active: true, focus: :chat}}

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{},
        windows: %Windows{},
        editing: VimState.new(),
        keymap_scope: :agent,
        agent_ui: agentic
      },
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tb, agent: agent}
    }
  end

  defp state_with_two_agent_tabs(session1, session2) do
    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, tab1} = TabBar.add(tb, :agent, "Agent 1")
    tb = TabBar.update_tab(tb, tab1.id, &Tab.set_session(&1, session1))
    {tb, tab2} = TabBar.add(tb, :agent, "Agent 2")
    tb = TabBar.update_tab(tb, tab2.id, &Tab.set_session(&1, session2))
    # First agent tab is active
    tb = TabBar.switch_to(tb, tab1.id)

    agent = %AgentState{runtime: %RuntimeState{status: :idle}}
    agentic = %UIState{view: %UIState.View{active: true, focus: :chat}}

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{},
        windows: %Windows{},
        editing: VimState.new(),
        keymap_scope: :agent,
        agent_ui: agentic
      },
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tb, agent: agent}
    }
  end

  defp state_with_two_tabs_file_active(session_pid) do
    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent 1")
    tb = TabBar.update_tab(tb, agent_tab.id, &Tab.set_session(&1, session_pid))

    agent_ctx = %{
      shell_state: %MingaEditor.Shell.Traditional.State{
        agent: %AgentState{runtime: %RuntimeState{status: :idle}}
      },
      agent_ui: %UIState{view: %UIState.View{active: true, focus: :chat}},
      windows: %Windows{},
      file_tree: nil,
      editing: VimState.new(),
      keymap_scope: :agent,
      active_buffer: nil,
      active_buffer_index: 0
    }

    tb = TabBar.update_context(tb, agent_tab.id, agent_ctx)
    # File tab (1) is active
    tb = TabBar.switch_to(tb, 1)

    agent = %AgentState{}
    agentic = %UIState{}

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{},
        windows: %Windows{},
        editing: VimState.new(),
        keymap_scope: :editor,
        agent_ui: agentic
      },
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tb, agent: agent}
    }
  end
end
