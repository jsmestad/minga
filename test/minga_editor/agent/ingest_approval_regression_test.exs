defmodule MingaEditor.Agent.IngestApprovalRegressionTest do
  @moduledoc """
  Regression for the #2289 local tool-approval path.

  When the foreground session is subscribed by the `MingaEditor.Agent.Ingest`
  coalescer, the Ingest process becomes the session's *driver* (first subscriber
  with the default :driver role). Local approvals are issued by the Editor, which
  is therefore *not* the driver. Routing them through the driver-gated
  `Session.respond_to_approval_as/4` returned `{:error, :not_driver}`: the user
  pressed `y`, the prompt cleared, and the agent hung forever because the blocked
  tool task never received its decision.

  These tests pin the two halves of the fix:

    * The editor's local approval path (`AgentSession.respond_to_approval_pid/3`)
      uses the ungated `Session.respond_to_approval/2`, so the decision reaches
      the blocked tool task even when Ingest holds the driver role.
    * `Commands.AgentSubStates` only clears the approval UI when the session
      accepts the decision; on an error it keeps the approval and surfaces the
      failure instead of silently dropping it.

  Uses a real `MingaAgent.Session` + real `Ingest` so the driver assignment and
  the blocked-task reply are the genuine production paths, not stubs.
  """

  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.Session
  alias MingaEditor.Agent.Ingest
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Commands.AgentSubStates
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaAgent.RuntimeState

  @event_timeout 5_000

  # Minimal provider: the session needs a provider pid and admitted turn, while
  # the tests inject the approval event instead of running a real tool.
  defmodule QuietProvider do
    @moduledoc false
    @behaviour MingaAgent.Provider
    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl MingaAgent.Provider
    def send_prompt(_pid, _text), do: :ok
    @impl MingaAgent.Provider
    def abort(_pid), do: :ok
    @impl MingaAgent.Provider
    def new_session(_pid), do: :ok
    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok
    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

    @impl GenServer
    def init(_opts), do: {:ok, %{}}
  end

  # Subscribe the session through a real Ingest process so Ingest, not the test
  # process, holds the driver role. This is the exact topology that broke local
  # approvals: the approver (here the test process, standing in for the Editor)
  # is not the driver.
  defp session_with_ingest_driver do
    {:ok, session} = Session.start_link(provider: QuietProvider)
    ingest = start_supervised!({Ingest, editor: self()})
    assert :ok = Ingest.subscribe_session(ingest, session)
    # Confirm the topology the bug depends on: Ingest is the driver, the test
    # process (the would-be Editor) is not.
    assert Session.subscriber_role(session, ingest) == :driver
    refute Session.subscriber_role(session, self()) == :driver
    %{session: session, ingest: ingest}
  end

  # Start a provider-owned turn, then inject a pending tool approval whose blocked
  # task is `reply_to`. The decision later flows back to `reply_to`.
  defp inject_pending_approval(session, reply_to) do
    assert :ok = Session.send_prompt(session, "approval turn")
    send(session, {:agent_provider_event, %Event.AgentStart{}})

    send(
      session,
      {:agent_provider_event,
       %Event.ToolApproval{
         tool_call_id: "tc1",
         name: "shell",
         args: %{"command" => "echo hi"},
         reply_to: reply_to
       }}
    )

    # Force a synchronous round-trip so the approval is registered before we act.
    Session.status(session)
    :ok
  end

  describe "local approval reaches the blocked tool task (CRITICAL regression)" do
    test "respond_to_approval_pid/3 delivers the decision even though Ingest is the driver" do
      %{session: session} = session_with_ingest_driver()
      inject_pending_approval(session, self())

      # The Editor (this process) is not the driver. The pre-fix gated path would
      # return {:error, :not_driver} and never reply to the blocked task.
      assert :ok = AgentSession.respond_to_approval_pid(session, "tc1", :approve)

      # The blocked tool task receives its decision: the tool proceeds.
      assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
    end

    test "the editor command path approves and clears the pending approval" do
      %{session: session} = session_with_ingest_driver()
      inject_pending_approval(session, self())

      approval = %{tool_call_id: "tc1", name: "shell", args: %{"command" => "echo hi"}}
      state = editor_state_with(session, approval)

      new_state = AgentSubStates.approve_tool(state)

      # The session advanced (blocked task unblocked) and the UI cleared because
      # the session accepted the decision.
      assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout

      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).pending_approval ==
               nil
    end
  end

  describe "silent-failure guard (CRITICAL regression, second half)" do
    test "an already-resolved approval clears the stale prompt and tells the user" do
      %{session: session} = session_with_ingest_driver()
      # No pending approval is injected, so the session replies
      # {:error, :no_pending_approval}: the approval already resolved and the
      # prompt is stale. The UI clears (retrying would re-fail forever) and the
      # user is told why, rather than the decision being silently swallowed.
      approval = %{tool_call_id: "tc1", name: "shell", args: %{"command" => "echo hi"}}
      state = editor_state_with(session, approval)

      new_state = AgentSubStates.approve_tool(state)

      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).pending_approval ==
               nil

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) =~ "already resolved"
      refute_receive {:tool_approval_response, _, _}, 200
    end
  end

  # Builds a minimal traditional-shell Editor state whose active agent session is
  # `session` and whose agent has the given pending approval.
  defp editor_state_with(session, approval) do
    agent_tab = Tab.new_agent(1, "Agent")
    tb = TabBar.new(agent_tab)
    {tb, ws} = TabBar.add_workspace(tb, "Agent", session)
    tb = TabBar.move_tab_to_workspace(tb, 1, ws.id) |> Map.put(:active_id, 1)

    tb =
      TabBar.set_workspace_session(tb, ws.id, session)

    agent = %AgentState{
      runtime: %RuntimeState{status: :idle},
      pending_approval: approval
    }

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
end
