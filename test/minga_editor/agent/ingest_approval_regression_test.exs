defmodule MingaEditor.Agent.IngestApprovalRegressionTest do
  @moduledoc """
  Local approval decisions remain request-bound when Ingest owns the driver subscription.

  These tests use a real Session and Ingest, with fixture provider requests and blocked-task replies. They prove that the Editor's trusted local operation does not require the remote driver role, and that stale controls cannot clear or resolve a newer request.
  """

  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.RuntimeState
  alias MingaAgent.Session
  alias MingaAgent.ToolApproval.Public
  alias MingaEditor.Agent.Ingest
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.TaskWorkflow
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Commands.AgentSubStates
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  @event_timeout 5_000

  test "the trusted local operation resolves the displayed target when Ingest is the driver" do
    %{session: session} = session_with_ingest_driver()
    approval = inject_pending_approval(session)

    assert :ok = AgentSession.respond_to_approval_pid(session, approval.target, :approve)
    assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
    assert Session.editor_snapshot(session).pending_approval == nil
  end

  test "the keyboard command resolves and clears its exact displayed attachment" do
    %{session: session} = session_with_ingest_driver()
    approval = inject_pending_approval(session)
    state = editor_state_with(session, approval)

    resolved = AgentSubStates.approve_tool(state)

    assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
    assert agent(resolved).pending_approval == nil
    assert Session.editor_snapshot(session).pending_approval == nil
  end

  test "an already resolved attachment is retired without sending another decision" do
    %{session: session} = session_with_ingest_driver()
    approval = inject_pending_approval(session)
    state = editor_state_with(session, approval)
    assert :ok = Session.respond_to_approval(session, approval.target, :approve)
    assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout

    resolved = AgentSubStates.approve_tool(state)

    assert agent(resolved).pending_approval == nil

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(resolved) ==
             "Already answered in Minga"

    refute_received {:tool_approval_response, _, _}
  end

  test "a delayed button cannot resolve or clear the next request reusing the same tool ID" do
    %{session: session} = session_with_ingest_driver()
    first = inject_pending_approval(session)
    assert :ok = Session.respond_to_approval(session, first.target, :approve)
    assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
    assert :ok = Session.abort(session)
    second = inject_pending_approval(session)
    refute second.target.request_id == first.target.request_id
    state = editor_state_with(session, second)
    binding = agent(state).pending_approval

    stale = AgentSubStates.respond_to_tool_approval(state, first.target, :approve_session)

    assert agent(stale).pending_approval == binding
    assert Session.editor_snapshot(session).pending_approval == second
    assert Session.list_tool_trust(session) == %{}

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(stale) =~
             "no decision was applied"

    refute_received {:tool_approval_response, _, _}

    resolved = AgentSubStates.respond_to_tool_approval(stale, second.target, :reject)

    assert_receive {:tool_approval_response, "tc1", :reject}, @event_timeout
    assert agent(resolved).pending_approval == nil
    assert Session.editor_snapshot(session).pending_approval == nil
  end

  test "answering in the conversation withdraws the task's needs-you alert" do
    %{session: session} = session_with_ingest_driver()
    approval = inject_pending_approval(session)
    registry = :"ingest_approval_events_#{System.unique_integer([:positive])}"
    start_supervised!({Minga.Events, name: registry})
    Minga.Events.subscribe(:agent_desktop_notification, registry: registry)
    alert = <<5::128>>

    state =
      session
      |> editor_state_with(approval)
      |> task_asks(session, approval)
      |> EditorState.post_agent_task_alert(session, alert)

    state = %{
      state
      | extension_surfaces:
          MingaEditor.State.ExtensionSurfaces.install_events_registry(
            state.extension_surfaces,
            registry
          )
    }

    resolved = AgentSubStates.approve_tool(state)

    assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
    assert Tasks.posted_alert(resolved.agent_connection.tasks, session) == nil

    assert_receive {:minga_event, :agent_desktop_notification,
                    %{kind: :withdrawn, id: ^alert, owner: ^session}}
  end

  describe "answering a task's approval from outside its conversation" do
    test "resolves the task's request and the conversation's copy together" do
      %{session: session} = session_with_ingest_driver()
      approval = inject_pending_approval(session)
      state = session |> editor_state_with(approval) |> task_asks(session, approval)

      answered = TaskWorkflow.answer(state, session, :approve)

      assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
      assert Tasks.approval(answered.agent_connection.tasks, session) == nil
      assert agent(answered).pending_approval == nil
    end

    test "a request answered elsewhere first says so and sends no decision" do
      %{session: session} = session_with_ingest_driver()
      approval = inject_pending_approval(session)
      state = session |> editor_state_with(approval) |> task_asks(session, approval)
      assert :ok = Session.respond_to_approval(session, approval.target, :approve)
      assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout

      answered = TaskWorkflow.answer(state, session, :reject)

      assert Tasks.approval(answered.agent_connection.tasks, session) == nil

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(answered) ==
               "Already answered in Minga"

      refute_received {:tool_approval_response, _, _}
    end

    test "a task with nothing pending says it was already answered" do
      %{session: session} = session_with_ingest_driver()
      approval = inject_pending_approval(session)
      state = editor_state_with(session, approval)

      answered = TaskWorkflow.answer(state, session, :approve)

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(answered) ==
               "Already answered in Minga"

      refute_received {:tool_approval_response, _, _}
    end
  end

  @spec task_asks(EditorState.t(), pid(), Public.t()) :: EditorState.t()
  defp task_asks(state, session, approval) do
    state
    |> TaskWorkflow.follow(session)
    |> TaskWorkflow.observe(session, {:approval_pending, approval})
  end

  @spec session_with_ingest_driver() :: %{session: pid(), ingest: pid()}
  defp session_with_ingest_driver do
    session =
      start_supervised!(
        {Session,
         provider: Minga.Test.SessionContinuationProvider,
         provider_opts: [test_pid: self()],
         persist?: false}
      )

    ingest = start_supervised!({Ingest, editor: self()})
    assert :ok = Ingest.subscribe_session(ingest, session)
    assert Session.subscriber_role(session, ingest) == :driver
    refute Session.subscriber_role(session, self()) == :driver
    %{session: session, ingest: ingest}
  end

  @spec inject_pending_approval(pid()) :: Public.t()
  defp inject_pending_approval(session) do
    assert :ok = Session.send_prompt(session, "approval turn")
    assert_receive {:continuation_request, request}, @event_timeout
    Minga.Test.SessionCase.send_provider_event(session, %Event.AgentStart{})

    Minga.Test.SessionCase.send_provider_event(
      session,
      %Event.ToolApproval{
        tool_call_id: "tc1",
        name: "shell",
        args: %{"command" => "echo hi"},
        reply_to: self()
      }
    )

    %{pending_approval: %Public{} = approval} = Session.editor_snapshot(session)
    assert approval.target.request_id == request.request_id
    approval
  end

  @spec editor_state_with(pid(), Public.t()) :: EditorState.t()
  defp editor_state_with(session, approval) do
    agent_tab = Tab.new_agent(1, "Agent")
    tb = TabBar.new(agent_tab)
    {tb, ws} = TabBar.add_workspace(tb, "Agent", session)
    tb = TabBar.move_tab_to_workspace(tb, 1, ws.id) |> Map.put(:active_id, 1)
    tb = TabBar.set_workspace_session(tb, ws.id, session)

    agent =
      AgentState.set_pending_approval(
        %AgentState{runtime: %RuntimeState{status: :idle}},
        PendingApproval.new(session, approval)
      )

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %TraditionalState{}
          |> TraditionalState.replace_agent(agent)
          |> TraditionalState.install_tab_bar(tb)
        )
    }
  end

  @spec agent(EditorState.t()) :: AgentState.t()
  defp agent(state), do: TraditionalState.agent(state.shell_runtime.state)
end
