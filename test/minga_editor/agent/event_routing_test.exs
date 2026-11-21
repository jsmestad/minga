defmodule MingaEditor.Agent.EventRoutingTest do
  @moduledoc """
  Verifies the foreground/background split for agent events.

  The runtime split lives in `MingaEditor.handle_info/2` for `:agent_event`
  messages: events whose `session_pid` matches `Shell.Runtime.active_session/1` go
  through `Agent.Events.dispatch/3` (rendering cache + tab status); the
  rest go through `Shell.on_agent_event/4` (presentation only — never
  the active tab's rendering cache).

  These tests pin the shell callbacks directly so the routing contract
  is exercised without booting the editor GenServer.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.Events
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaAgent.Event
  alias MingaAgent.Session
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.ToolApproval.Preview, as: ApprovalPreview
  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Remote
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.VimState
  alias MingaEditor.Session.State, as: SessionState

  defp workspace, do: %SessionState{editing: VimState.new()}

  defp event_state(agent) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: nil},
      workspace: %SessionState{agent_ui: UIState.new()},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          TraditionalState.replace_agent(%TraditionalState{}, agent)
        )
    }
  end

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
        %{acc | tabs: Enum.concat(acc.tabs, [tab]), next_id: max(acc.next_id, tab.id + 1)}
      end)

    %{tb | active_id: active_id}
  end

  # ── Traditional shell ──────────────────────────────────────────────────

  describe "Traditional.on_agent_event/4" do
    setup do
      session_a = fake_session_pid()
      session_b = fake_session_pid()

      tb = tab_bar([Tab.new_agent(1, "A"), Tab.new_agent(2, "B")], 1)
      {tb, workspace_a} = TabBar.add_workspace(tb, "A")
      {tb, workspace_b} = TabBar.add_workspace(tb, "B")

      tb =
        tb
        |> TabBar.move_tab_to_workspace(1, workspace_a.id)
        |> TabBar.move_tab_to_workspace(2, workspace_b.id)
        |> TabBar.set_workspace_session(workspace_a.id, session_a)
        |> TabBar.set_workspace_session(workspace_b.id, session_b)

      shell_state =
        TraditionalState.install_tab_bar(
          TraditionalState.replace_agent(%TraditionalState{}, %AgentState{}),
          tb
        )

      %{shell_state: shell_state, session_a: session_a, session_b: session_b}
    end

    test "background display status owns the badge without changing the active rendering cache",
         %{shell_state: ss, session_b: session_b} do
      {ss2, ws2} =
        Traditional.on_agent_event(
          ss,
          workspace(),
          session_b,
          {:display_status_changed, :thinking}
        )

      # Background tab's badge updates...
      assert tab(ss2.tab_bar, 2).payload.agent_status == :thinking

      # ...but the active rendering cache is untouched (it routes through
      # Agent.Events for the foreground path, not through this callback).
      assert TraditionalState.agent(ss2) == TraditionalState.agent(ss)

      # Workspace is also untouched: background events must not nudge the
      # active tab's editing surface.
      assert ws2 == workspace()

      {waiting, _ws} =
        Traditional.on_agent_event(
          ss2,
          workspace(),
          session_b,
          {:display_status_changed, :approval_waiting}
        )

      {unchanged, _ws} =
        Traditional.on_agent_event(waiting, workspace(), session_b, {:status_changed, :thinking})

      assert tab(unchanged.tab_bar, 2).payload.agent_status == :approval_waiting
      assert TraditionalState.agent(unchanged) == TraditionalState.agent(ss)
    end

    test "background :status_changed -> :idle raises attention on the owning tab", %{
      shell_state: ss,
      session_b: session_b
    } do
      {ss2, _ws} =
        Traditional.on_agent_event(ss, workspace(), session_b, {:status_changed, :idle})

      assert tab(ss2.tab_bar, 2).payload.attention == true
      assert tab(ss2.tab_bar, 1).payload.attention == false
    end

    test "background approval raises its tab's attention without replacing the foreground attachment",
         %{
           shell_state: ss,
           session_a: session_a,
           session_b: session_b
         } do
      preview = ApprovalPreview.new(:command, "echo hello", ["echo hello"])

      foreground =
        PublicApproval.new(
          ApprovalTarget.new("session-A", "request-A", "reused-tool-id"),
          "shell",
          %{"command" => "echo hello"},
          preview
        )

      background =
        PublicApproval.new(
          ApprovalTarget.new("session-B", "request-B", "reused-tool-id"),
          "shell",
          %{"command" => "echo hello"},
          preview
        )

      agent =
        AgentState.set_pending_approval(
          TraditionalState.agent(ss),
          PendingApproval.new(session_a, foreground)
        )

      ss = TraditionalState.replace_agent(ss, agent)

      {ss2, ws2} =
        Traditional.on_agent_event(ss, workspace(), session_b, {:approval_pending, background})

      assert tab(ss2.tab_bar, 2).payload.attention == true
      assert tab(ss2.tab_bar, 1).payload.attention == false
      assert TraditionalState.agent(ss2) == agent
      assert ws2 == workspace()

      # A background resolution cannot clear the active presentation, even with its exact target.
      for target <- [background.target, foreground.target] do
        assert Traditional.on_agent_event(
                 ss2,
                 workspace(),
                 session_b,
                 {:approval_resolved, target, :approve}
               ) == {ss2, workspace()}
      end
    end

    test "background :error raises attention on the owning tab", %{
      shell_state: ss,
      session_b: session_b
    } do
      {ss2, _ws} = Traditional.on_agent_event(ss, workspace(), session_b, {:error, "boom"})

      assert tab(ss2.tab_bar, 2).payload.attention == true
      assert tab(ss2.tab_bar, 1).payload.attention == false
    end

    test "background :text_delta does not mutate state at all", %{
      shell_state: ss,
      session_b: session_b
    } do
      # Streaming text from a background session must not reach this callback's
      # mutation path — the delta is purely a no-op so the active tab's UI
      # never re-renders for unrelated streaming.
      {ss2, ws2} = Traditional.on_agent_event(ss, workspace(), session_b, {:text_delta, "hello"})

      assert ss2 == ss
      assert ws2 == workspace()
    end

    test "events from a session that no longer maps to any tab are silently dropped", %{
      shell_state: ss
    } do
      ghost = spawn(fn -> :ok end)

      approval =
        PublicApproval.new(
          ApprovalTarget.new("detached-session", "detached-request", "tc-detached"),
          "shell",
          %{"command" => "echo detached"},
          ApprovalPreview.new(:command, "echo detached", ["echo detached"])
        )

      for event <- [
            {:status_changed, :error},
            {:approval_pending, approval},
            {:approval_resolved, approval.target, :reject}
          ] do
        assert Traditional.on_agent_event(ss, workspace(), ghost, event) == {ss, workspace()}
      end
    end
  end

  describe "Agent.Events.dispatch/3 model selection" do
    test "installs an accepted exact selection in the foreground panel" do
      selection =
        ModelSelectionFixture.selection(
          display_name: "Accepted Model",
          model_provider: "openai",
          reasoning: %{
            effort: "high",
            options: ["off", "low", "medium", "high"]
          }
        )

      state =
        Events.dispatch(event_state(%AgentState{}), self(), {:model_selection_changed, selection})

      assert state.workspace.agent_ui.panel.model_name == "Accepted Model"
      assert state.workspace.agent_ui.panel.provider_name == "openai"
      assert state.workspace.agent_ui.panel.thinking_level == "high"

      assert state.workspace.agent_ui.view.toast == %{
               message:
                 "Model activated: Accepted Model via openai/#{selection.route.execution.wire_protocol}",
               icon: "✓",
               level: :info
             }
    end

    test "does not replace the visible model when an exact selection is rejected" do
      selection = ModelSelectionFixture.selection(display_name: "Rejected Model")

      state =
        event_state(%AgentState{})
        |> then(fn state ->
          ui = UIState.set_model_name(state.workspace.agent_ui, "Active Model")
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)
        end)
        |> Events.dispatch(
          self(),
          {:model_selection_rejected, selection, "The model is unavailable"}
        )

      assert state.workspace.agent_ui.panel.model_name == "Active Model"

      assert state.workspace.agent_ui.view.toast == %{
               message: "The model is unavailable",
               icon: "✗",
               level: :error
             }
    end
  end

  describe "Agent.Events.dispatch/3 tool status" do
    test "tool_started and tool_ended keep active_tool_name synced with the session snapshot" do
      {:ok, session} = start_supervised({Session, provider_opts: []})
      :sys.get_state(session)
      assert :ok = Session.send_prompt(session, "route tool events")

      {tab_bar, workspace} =
        TabBar.add_workspace(TabBar.new(Tab.new_agent(1, "Agent")), "Agent", session)

      tab_bar = TabBar.move_tab_to_workspace(tab_bar, 1, workspace.id)

      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: nil},
        workspace: workspace(),
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            TraditionalState.install_tab_bar(
              TraditionalState.replace_agent(%TraditionalState{}, %AgentState{}),
              tab_bar
            )
          )
      }

      Minga.Test.SessionCase.send_provider_event(
        session,
        %Event.ToolStart{tool_call_id: "tc1", name: "alpha", args: %{}}
      )

      :sys.get_state(session)
      state = Events.dispatch(state, session, {:tool_started, "alpha", %{}})

      assert AgentState.active_tool_name(
               MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
             ) == "alpha"

      Minga.Test.SessionCase.send_provider_event(
        session,
        %Event.ToolStart{tool_call_id: "tc2", name: "beta", args: %{}}
      )

      :sys.get_state(session)
      state = Events.dispatch(state, session, {:tool_started, "beta", %{}})

      assert AgentState.active_tool_name(
               MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
             ) == "beta"

      alpha_end = %Event.ToolEnd{
        tool_call_id: "tc1",
        name: "alpha",
        result: "contents",
        outcome: :complete
      }

      Minga.Test.SessionCase.send_provider_event(session, alpha_end)

      :sys.get_state(session)
      state = Events.dispatch(state, session, {:tool_ended, alpha_end})

      assert AgentState.active_tool_name(
               MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
             ) == "beta"

      beta_end = %Event.ToolEnd{
        tool_call_id: "tc2",
        name: "beta",
        result: "output",
        outcome: :complete
      }

      Minga.Test.SessionCase.send_provider_event(session, beta_end)

      :sys.get_state(session)
      state = Events.dispatch(state, session, {:tool_ended, beta_end})

      assert AgentState.active_tool_name(
               MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
             ) == nil
    end

    test "tool_started and tool_ended update an editor without an agent session" do
      state = event_state(%AgentState{})

      state = Events.dispatch(state, self(), {:tool_started, "read_file", %{}})

      assert AgentState.active_tool_name(
               MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
             ) == "read_file"

      event = %Event.ToolEnd{
        tool_call_id: "no-session-tool",
        name: "read_file",
        result: "contents",
        outcome: :complete
      }

      state = Events.dispatch(state, self(), {:tool_ended, event})

      assert AgentState.active_tool_name(
               MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
             ) == nil
    end

    test "status_changed clears active_tool_name outside tool execution" do
      agent = %AgentState{} |> AgentState.set_active_tool_name("read_file")
      state = event_state(agent)

      state = Events.dispatch(state, self(), {:status_changed, :tool_executing})

      assert AgentState.active_tool_name(
               MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
             ) == "read_file"

      state = Events.dispatch(state, self(), {:status_changed, :idle})

      assert AgentState.active_tool_name(
               MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
             ) == nil
    end

    test "context usage while busy defers auto-compaction" do
      session = fake_session_pid()
      agent = %AgentState{} |> AgentState.set_status(:thinking)

      {tab_bar, workspace} =
        TabBar.add_workspace(TabBar.new(Tab.new_agent(1, "Agent")), "Agent", session)

      tab_bar = TabBar.move_tab_to_workspace(tab_bar, 1, workspace.id)

      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: self()},
        workspace: %SessionState{agent_ui: UIState.new()},
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            TraditionalState.install_tab_bar(
              TraditionalState.replace_agent(%TraditionalState{}, agent),
              tab_bar
            )
          )
      }

      state = Events.dispatch(state, session, {:context_usage, 95, 100})
      assert state.workspace.agent_ui.view.compaction.execution == {:deferred, 95}
      assert state.workspace.agent_ui.view.compaction.threshold == :fresh
    end
  end

  describe "background writes through Events and input routing" do
    test "the next character edits the human buffer, not the arriving diff" do
      state = background_input_state(keymap_scope: :editor)
      buffer = state.workspace.buffers.active
      BufferProcess.move_to(buffer, {0, 6})
      workspace = SessionState.transition_mode(state.workspace, :insert)
      state = %{state | workspace: workspace}

      state =
        Events.dispatch(
          state,
          self(),
          {:file_changed, "/tmp/agent-b.ex", "b0", "b1", "b1", "edit"}
        )

      assert BufferProcess.cursor(buffer) == {0, 6}

      state = Router.route_key(state, ?x, 0)

      assert BufferProcess.content(buffer) == "hello xworld"
      assert BufferProcess.cursor(buffer) == {0, 7}
      assert PromptBuffer.prompt_text(state.workspace.agent_ui) == ""
      assert_retained_review(state, "/tmp/agent-b.ex", "b0", "b1")
    end

    test "normal, working, waiting, failed and recovered writes keep typing in the draft" do
      for status <- [:idle, :thinking, :tool_executing, :error, :idle] do
        state =
          background_input_state(
            keymap_scope: :agent,
            agentic_active: true,
            panel_visible: true,
            input_focused: true
          )

        prompt = state.workspace.agent_ui.panel.prompt_buffer
        buffer = state.workspace.buffers.active
        BufferProcess.insert_text(prompt, "draft ")
        state = Events.dispatch(state, self(), {:status_changed, status})
        ui = UIState.scroll_down(state.workspace.agent_ui, 7)
        state = TraditionalWorkflow.install_agent_ui(state, ui)

        state =
          Events.dispatch(
            state,
            self(),
            {:file_changed, "/tmp/agent-b.ex", "b0", "b1", "b1", "edit"}
          )

        assert PromptBuffer.input_cursor(state.workspace.agent_ui) == {0, 6}
        assert state.workspace.agent_ui.view.presentation.focus == :chat
        assert state.workspace.agent_ui.panel.scroll == ui.panel.scroll
        state = Router.route_key(state, ?x, 0)
        assert PromptBuffer.prompt_text(state.workspace.agent_ui) == "draft x"
        assert BufferProcess.content(buffer) == "hello world"
        assert_retained_review(state, "/tmp/agent-b.ex", "b0", "b1")
      end
    end

    test "same-process conversation restore clears the old review and ignores a queued file change" do
      pid = self()
      path = "/tmp/agent-a.ex"

      connection = %MingaAgent.Session.ConnectionSnapshot{
        target: MingaAgent.Session.ConnectionTarget.new(pid, "conversation-a", nil, make_ref()),
        conversation: make_ref(),
        credential_readiness: :checking,
        model_selection: nil,
        provider_phase: :stopped,
        operation: :idle,
        problem: nil
      }

      state = background_input_state(keymap_scope: :agent, agentic_active: true)
      ui = UIState.project_connection(state.workspace.agent_ui, connection)
      stale = {:file_changed, connection.conversation, path, "a0", "a1", "a1", "edit"}

      state =
        state
        |> TraditionalWorkflow.install_agent_ui(ui)
        |> Events.dispatch(pid, stale)
        |> select_retained_review(path)

      assert_retained_review(state, path, "a0", "a1")

      restored = %{
        connection
        | target: MingaAgent.Session.ConnectionTarget.new(pid, "conversation-a", nil, make_ref()),
          conversation: make_ref()
      }

      ui = UIState.project_connection(state.workspace.agent_ui, restored)
      state = state |> TraditionalWorkflow.install_agent_ui(ui) |> Events.dispatch(pid, stale)
      assert EditTimeline.file_summaries(state.workspace.agent_ui.view.edit_timeline) == []
      assert Preview.diff_review(state.workspace.agent_ui.view.preview) == nil
    end

    test "another file's revisions leave the selected diff and its reading anchor intact" do
      state =
        background_input_state(
          keymap_scope: :agent,
          agentic_active: true
        )
        |> Events.dispatch(self(), {:file_changed, "/tmp/agent-a.ex", "a0", "a1", "a1", "edit"})
        |> select_retained_review("/tmp/agent-a.ex")

      preview = state.workspace.agent_ui.view.preview |> Preview.scroll_down(4)
      state = install_preview(state, preview)

      state =
        state
        |> Events.dispatch(self(), {:file_changed, "/tmp/agent-b.ex", "b0", "b1", "b1", "edit"})
        |> Events.dispatch(self(), {:file_changed, "/tmp/agent-b.ex", "b1", "b2", "b2", "edit"})

      assert state.workspace.agent_ui.view.preview == preview
      assert_retained_review(state, "/tmp/agent-a.ex", "a0", "a1")
      assert_retained_review(state, "/tmp/agent-b.ex", "b0", "b2")

      assert EditTimeline.content_at(
               state.workspace.agent_ui.view.edit_timeline,
               "/tmp/agent-b.ex",
               0
             ) ==
               {:ok, "b1"}

      # The next navigation key still belongs to the chat being read, not the diff.
      offset = state.workspace.agent_ui.panel.scroll.offset
      state = Router.route_key(state, ?j, 0)
      assert state.workspace.agent_ui.panel.scroll.offset == offset + 1
      assert state.workspace.agent_ui.view.preview == preview
    end

    test "a selected same-file revision invalidates stale decisions without redirecting input" do
      state =
        background_input_state(keymap_scope: :editor)
        |> Events.dispatch(self(), {:file_changed, "/tmp/agent-a.ex", "a0", "a1", "a1", "edit"})
        |> select_retained_review("/tmp/agent-a.ex")

      preview =
        state.workspace.agent_ui.view.preview
        |> Preview.update_diff(&DiffReview.accept_all/1)
        |> Preview.scroll_down(4)

      state = install_preview(state, preview)
      workspace = SessionState.transition_mode(state.workspace, :insert)
      state = %{state | workspace: workspace}

      state =
        Events.dispatch(
          state,
          self(),
          {:file_changed, "/tmp/agent-a.ex", "a1", "a2", "a2", "edit"}
        )

      updated = state.workspace.agent_ui.view.preview
      assert Preview.diff_review(updated) == nil
      assert updated.content == preview.content
      assert updated.scroll == preview.scroll
      assert updated.freshness == :stale
      assert Preview.update_diff(updated, &DiffReview.reject_all/1) == updated
      assert state.workspace.agent_ui.view.presentation.focus == :chat

      state = Router.route_key(state, ?x, 0)
      assert BufferProcess.content(state.workspace.buffers.active) == "xhello world"
      assert_retained_review(state, "/tmp/agent-a.ex", "a0", "a2")
    end

    test "streaming a hundred changed files retains every edit while the human keeps typing" do
      state = background_input_state(keymap_scope: :editor)
      workspace = SessionState.transition_mode(state.workspace, :insert)
      state = %{state | workspace: workspace}

      preview =
        Preview.new() |> Preview.set_file("/tmp/human.ex", "reading") |> Preview.scroll_down(9)

      state = install_preview(state, preview)

      state =
        Enum.reduce(1..100, state, fn index, state ->
          path = "/tmp/agent-burst-#{index}.ex"

          state =
            state
            |> Events.dispatch_batch([{:text_delta, "stream #{index}"}])
            |> Events.dispatch(
              self(),
              {:file_changed, path, "original #{index}", "first #{index}", "first-#{index}",
               "edit"}
            )
            |> Events.dispatch(
              self(),
              {:file_changed, path, "first #{index}", "latest #{index}", "latest-#{index}",
               "edit"}
            )

          assert state.workspace.agent_ui.view.presentation.focus == :chat
          assert state.workspace.agent_ui.view.preview == preview
          Router.route_key(state, ?x, 0)
        end)

      assert BufferProcess.content(state.workspace.buffers.active) ==
               String.duplicate("x", 100) <> "hello world"

      assert Activity.file_count(state.workspace.agent_ui.view.activity) == 100
      timeline = state.workspace.agent_ui.view.edit_timeline
      assert length(EditTimeline.file_summaries(timeline)) == 100

      for index <- 1..100 do
        path = "/tmp/agent-burst-#{index}.ex"
        assert EditTimeline.entry_count(timeline, path) == 2
        assert EditTimeline.content_at(timeline, path, 0) == {:ok, "first #{index}"}
        assert EditTimeline.content_at(timeline, path, 1) == {:ok, "latest #{index}"}
        assert_retained_review(state, path, "original #{index}", "latest #{index}")
      end
    end

    test "a dirty remote buffer keeps the next character and retains the agent conflict for review" do
      state = background_input_state(keymap_scope: :editor)
      buffer = state.workspace.buffers.active
      BufferProcess.insert_text(buffer, "human ")
      cursor = BufferProcess.cursor(buffer)
      remote = Remote.put_buffer(state.remote, "remote-server", "/tmp/agent-remote.ex", buffer)
      workspace = SessionState.transition_mode(state.workspace, :insert)
      state = %{state | remote: remote, workspace: workspace}

      state =
        Events.dispatch(
          state,
          self(),
          {:file_changed, "/tmp/agent-remote.ex", "original", "agent edit", "remote", "edit"}
        )

      assert TraditionalState.modal(state.shell_runtime.state) == :none
      assert BufferProcess.cursor(buffer) == cursor
      assert Remote.buffer(state.remote, "remote-server", "/tmp/agent-remote.ex") == buffer

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(state) =~
               "Review agent changes or keep editing"

      assert_retained_review(state, "/tmp/agent-remote.ex", "original", "agent edit")

      state = Router.route_key(state, ?x, 0)
      assert BufferProcess.content(buffer) == "human xhello world"
      assert BufferProcess.dirty?(buffer)
      assert state.workspace.agent_ui.view.presentation.focus == :chat
    end

    test "approval arrival preserves the draft and intervening writes retain the bound approval" do
      state =
        background_input_state(
          keymap_scope: :agent,
          agentic_active: true,
          panel_visible: true,
          input_focused: true
        )

      approval =
        PublicApproval.new(
          ApprovalTarget.new("background-session", "admitted-request", "approval"),
          "shell",
          %{"command" => "pwd"},
          ApprovalPreview.new(:command, "pwd", ["pwd"])
        )

      state =
        Events.dispatch(
          state,
          self(),
          {:file_changed, "/tmp/agent-a.ex", "a0", "a1", "a1", "edit"}
        )

      assert state.workspace.agent_ui.panel.input_focused
      state = Events.dispatch(state, self(), {:approval_pending, approval})
      assert state.workspace.agent_ui.panel.input_focused

      state =
        Events.dispatch(
          state,
          self(),
          {:file_changed, "/tmp/agent-b.ex", "b0", "b1", "b1", "edit"}
        )

      assert state.workspace.agent_ui.panel.input_focused

      assert TraditionalState.agent(state.shell_runtime.state).pending_approval ==
               PendingApproval.new(self(), approval)

      assert_retained_review(state, "/tmp/agent-a.ex", "a0", "a1")
      assert_retained_review(state, "/tmp/agent-b.ex", "b0", "b1")
    end

    test "a failed remote reload logs file context and retains the edit without diverting typing" do
      dead = spawn(fn -> :ok end)
      monitor = Process.monitor(dead)
      assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}

      state = background_input_state(keymap_scope: :editor)
      remote = Remote.put_buffer(state.remote, "unavailable-server", "/tmp/agent-remote.ex", dead)
      workspace = SessionState.transition_mode(state.workspace, :insert)
      state = %{state | remote: remote, workspace: workspace}

      {state, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Events.dispatch(
            state,
            self(),
            {:file_changed, "/tmp/agent-remote.ex", "old", "new", "remote", "edit"}
          )
        end)

      assert log =~ "/tmp/agent-remote.ex"

      state = Router.route_key(state, ?x, 0)
      assert BufferProcess.content(state.workspace.buffers.active) == "xhello world"
      assert_retained_review(state, "/tmp/agent-remote.ex", "old", "new")
    end
  end

  # Materialize the retained review through its public consumer contract, without
  # relying on background arrival to select it. Explicit Review UI is covered separately.
  defp retained_review(state, path) do
    timeline = state.workspace.agent_ui.view.edit_timeline
    index = EditTimeline.entry_count(timeline, path) - 1
    assert {:ok, content} = EditTimeline.content_at(timeline, path, index)
    DiffReview.from_hunks(path, content, EditTimeline.cumulative_hunks(timeline, path))
  end

  defp assert_retained_review(state, path, before_content, after_content) do
    review = retained_review(state, path)
    assert %DiffReview{path: ^path} = review
    assert DiffReview.original_lines(review) == String.split(before_content, "\n")
    assert DiffReview.materialized_lines(review) == String.split(after_content, "\n")
  end

  defp select_retained_review(state, path) do
    install_preview(state, Preview.set_diff(Preview.new(), retained_review(state, path)))
  end

  defp background_input_state(opts) do
    state = Minga.Test.ScopedInputHelpers.base_state(opts)
    # This suite drives the public input/event owners, not a live frontend.
    # The generic input fixture's self() port cannot answer renderer calls.
    %{state | frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: nil}}
  end

  defp install_preview(state, preview) do
    TraditionalWorkflow.install_agent_ui(
      state,
      UIState.replace_preview(state.workspace.agent_ui, preview)
    )
  end

  describe "Agent.Events.dispatch/3 file association" do
    test "file_changed associates by exact file ref, not duplicate basename" do
      root = Path.join(System.tmp_dir!(), "minga-event-routing")
      lib_path = Path.join([root, "lib", "user.ex"])
      test_path = Path.join([root, "test", "user.ex"])
      assert {:ok, lib_ref} = FileRef.from_path(root, lib_path)
      assert {:ok, test_ref} = FileRef.from_path(root, test_path)

      session = fake_session_pid()
      tab1 = Tab.new_file(1, "user.ex") |> Tab.set_file_ref(lib_ref)
      tab2 = Tab.new_file(2, "user.ex") |> Tab.set_file_ref(test_ref)
      agent_tab = Tab.new_agent(3, "Agent")

      tb = TabBar.new(tab1, root)
      tb = %{tb | tabs: [tab1, tab2, agent_tab], active_id: 3, next_id: 4}
      {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
      tb = TabBar.move_tab_to_workspace(tb, agent_tab.id, workspace.id)

      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: self()},
        workspace:
          %SessionState{}
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            TraditionalState.install_tab_bar(
              TraditionalState.replace_agent(%TraditionalState{}, %AgentState{}),
              tb
            )
          )
      }

      state =
        Events.dispatch(
          state,
          session,
          {:file_changed, test_path, "before", "after", "tc_test", "edit_file"}
        )

      tb = state.shell_runtime.state.tab_bar
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
      agent_tab = Tab.new_agent(3, "Agent")

      tb = TabBar.new(tab1, root)
      tb = %{tb | tabs: [tab1, tab2, agent_tab], active_id: 3, next_id: 4}
      {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
      tb = TabBar.move_tab_to_workspace(tb, agent_tab.id, workspace.id)

      tb =
        tb
        |> TabBar.add_workspace_file(workspace.id, active_ref)

      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: self()},
        workspace:
          %SessionState{}
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            TraditionalState.install_tab_bar(
              TraditionalState.replace_agent(%TraditionalState{}, %AgentState{}),
              tb
            )
          )
      }

      state =
        Events.dispatch(
          state,
          session,
          {:file_changed, test_path, "before", "after", "tc_test", "edit_file"}
        )

      tb = state.shell_runtime.state.tab_bar
      agent_workspace = TabBar.get_workspace(tb, workspace.id)
      assert TabBar.get(tb, tab2.id).group_id == workspace.id
      assert Workspace.has_file?(agent_workspace, test_ref)
      assert Workspace.has_file?(agent_workspace, active_ref)
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

      agent_tab = Tab.new_agent(2, "Agent")

      tb = TabBar.new(file_tab, root)
      tb = %{tb | tabs: [file_tab, agent_tab], active_id: 2, next_id: 3}
      {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
      tb = TabBar.move_tab_to_workspace(tb, agent_tab.id, workspace.id)

      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: self()},
        workspace:
          %SessionState{}
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            TraditionalState.install_tab_bar(
              TraditionalState.replace_agent(%TraditionalState{}, %AgentState{}),
              tb
            )
          )
      }

      state =
        Events.dispatch(
          state,
          session,
          {:file_changed, path, "before", "after", "tc_test", "edit_file"}
        )

      tb = state.shell_runtime.state.tab_bar
      assert TabBar.get(tb, file_tab.id).group_id == workspace.id
      assert Workspace.has_file?(TabBar.get_workspace(tb, workspace.id), expected_ref)
    end

    test "file_changed outside the project root leaves workspace associations untouched" do
      root = Path.join(System.tmp_dir!(), "minga-event-routing-root")
      path = Path.join(System.tmp_dir!(), "minga-event-routing-outside.ex")
      session = fake_session_pid()

      file_tab = Tab.new_file(1, "initial.ex")
      agent_tab = Tab.new_agent(2, "Agent")

      tb = TabBar.new(file_tab, root)
      tb = %{tb | tabs: [file_tab, agent_tab], active_id: 2, next_id: 3}
      {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
      tb = TabBar.move_tab_to_workspace(tb, agent_tab.id, workspace.id)

      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: self()},
        workspace:
          %SessionState{}
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            TraditionalState.install_tab_bar(
              TraditionalState.replace_agent(%TraditionalState{}, %AgentState{}),
              tb
            )
          )
      }

      state =
        Events.dispatch(
          state,
          session,
          {:file_changed, path, "before", "after", "tc_test", "edit_file"}
        )

      tb = state.shell_runtime.state.tab_bar
      assert TabBar.get(tb, file_tab.id).group_id == 0
      assert TabBar.get(tb, agent_tab.id).group_id == workspace.id
      assert TabBar.get_workspace(tb, workspace.id).files == []
    end
  end
end
