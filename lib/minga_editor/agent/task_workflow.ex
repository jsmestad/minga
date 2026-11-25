defmodule MingaEditor.Agent.TaskWorkflow do
  @moduledoc """
  Keeps the editor's tasks (`MingaEditor.Agent.Tasks`) in step with the sessions it follows, and answers a task's approval from wherever it is shown.

  The Editor calls `observe/3` for every session event before routing it, so a background task's approval and state are kept even though only the active conversation renders them. Session starts, background subagents, restarts and stops arrive through the other entry points.

  `answer/3` is the one way to answer a task's approval from outside its conversation (the tasks drawer, a notification). The session decides: an approval it already resolved, answered elsewhere, is refused, and the editor then says "Already answered in Minga".
  """

  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaAgent.Subagent.Handle
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState

  @typedoc "How an approval is answered: once, for the session, for the turn, or denied."
  @type decision :: MingaAgent.Session.approval_decision()

  @already_answered "Already answered in Minga"

  @doc "The words shown when an approval was answered somewhere else first."
  @spec already_answered() :: String.t()
  def already_answered, do: @already_answered

  @doc "Applies one session event to its task."
  @spec observe(EditorState.t(), pid(), term()) :: EditorState.t()
  def observe(%EditorState{} = state, session, event) when is_pid(session),
    do: EditorState.observe_agent_task_event(state, session, event, now())

  @doc "Follows a session the editor started or attached to, named by its goal when known."
  @spec follow(EditorState.t(), pid(), keyword()) :: EditorState.t()
  def follow(%EditorState{} = state, session, opts \\ []) when is_pid(session),
    do: EditorState.follow_agent_task(state, session, now(), opts)

  @doc "Follows a background subagent beneath the task that started it."
  @spec follow_subagent(EditorState.t(), Handle.t()) :: EditorState.t()
  def follow_subagent(%EditorState{} = state, %Handle{} = handle) do
    opts = [title: handle.task, parent: handle.parent_pid] |> Enum.reject(&is_nil(elem(&1, 1)))
    follow(state, handle.pid, opts)
  end

  @doc "Shows a task started from the drawer at once, before its session binds. Returns the state and the task's row id."
  @spec start(EditorState.t(), reference(), String.t()) :: {EditorState.t(), String.t()}
  def start(%EditorState{} = state, id, goal) when is_reference(id) and is_binary(goal) do
    {state, seq} = EditorState.start_agent_task(state, id, goal, now())
    {state, "t#{seq}"}
  end

  @doc "Turns a starting task into the task of the session that bound for it."
  @spec bound(EditorState.t(), reference(), pid()) :: EditorState.t()
  def bound(%EditorState{} = state, id, session) when is_pid(session),
    do: EditorState.bind_agent_task(state, id, session, now())

  @doc "Shows that a drawer-started task could not start, for a start whose follow-up was that task's goal."
  @spec start_failed(EditorState.t(), term(), String.t()) :: EditorState.t()
  def start_failed(%EditorState{} = state, {:prompt, _goal, id}, message) when is_reference(id),
    do: EditorState.fail_agent_task_start(state, id, message)

  def start_failed(%EditorState{} = state, _follow_up, _message), do: state

  @doc "Carries a task over to the session that replaced its crashed one."
  @spec restarted(EditorState.t(), pid(), pid()) :: EditorState.t()
  def restarted(%EditorState{} = state, old, new) when is_pid(old) and is_pid(new),
    do: EditorState.replace_agent_task_session(state, old, new, now())

  @doc "Stops following a session that ended."
  @spec stopped(EditorState.t(), pid()) :: EditorState.t()
  def stopped(%EditorState{} = state, session) when is_pid(session),
    do: EditorState.forget_agent_task(state, session)

  @doc "Stops following every task on a remote node that disconnected."
  @spec node_disconnected(EditorState.t(), node()) :: EditorState.t()
  def node_disconnected(%EditorState{} = state, node) when is_atom(node),
    do: EditorState.forget_agent_node_tasks(state, node)

  @doc """
  Answers the approval task `session` is waiting on.

  The session resolves the exact request the task showed. When it is no longer pending, because it was answered in the conversation, the drawer or a notification, the task's copy is cleared and the echo area says "Already answered in Minga".
  """
  @spec answer(EditorState.t(), pid(), decision()) :: EditorState.t()
  def answer(%EditorState{} = state, session, decision) when is_pid(session) do
    case Tasks.approval(state.agent_connection.tasks, session) do
      %PendingApproval{approval: %PublicApproval{target: target}} ->
        session
        |> AgentSession.respond_to_approval_pid(target, decision)
        |> answered(state, session, target)

      nil ->
        NoticeWorkflow.publish(state, @already_answered)
    end
  end

  @spec answered(
          :ok | {:error, term()},
          EditorState.t(),
          pid(),
          MingaAgent.ToolApproval.Target.t()
        ) ::
          EditorState.t()
  defp answered(:ok, state, session, target), do: resolve(state, session, target)

  defp answered({:error, reason}, state, session, target)
       when reason in [:no_pending_approval, :approval_not_found] do
    state
    |> resolve(session, target)
    |> NoticeWorkflow.publish(@already_answered)
  end

  defp answered({:error, reason}, state, _session, _target) do
    Minga.Log.warning(:agent, "[Agent] task approval answer failed: #{inspect(reason)}")
    NoticeWorkflow.publish(state, "Could not answer the approval: #{inspect(reason)}")
  end

  # The task's copy and the conversation's copy are cleared together, so neither shows a request the session resolved.
  @spec resolve(EditorState.t(), pid(), MingaAgent.ToolApproval.Target.t()) :: EditorState.t()
  defp resolve(state, session, target) do
    state
    |> EditorState.resolve_agent_task_approval(session, target)
    |> TraditionalWorkflow.resolve_agent_approval(target, session)
  end

  @spec now() :: integer()
  defp now, do: System.os_time(:millisecond)
end
