defmodule MingaEditor.Agent.SessionFollowUp do
  @moduledoc """
  Work the Editor sent to a newly started Agent session and has not seen answered.

  A start can carry a follow-up: Restore loads a saved conversation, and an Inline Ask promote seeds its answered history. The follow-up runs once the session binds to its workspace, and the session handles it only after provider start, so the Editor never waits for the session to do it. It sends one `:gen_server.send_request/2` and keeps this record until the reply arrives. The request monitors the session, so a session that exits answers with its exit.

  A Restore runs whether or not its workspace is in front. Its draft guard and its view changes apply only when the workspace is in front; a workspace in the background shows the restored conversation through its arrival when the user returns.

  An error reply is shown in the session's own conversation. A session that exits, or does not answer before the deadline, is reported in a notice because the session cannot show it. A reply after the deadline still settles the follow-up. These functions return the next state; the Editor schedules the render.
  """

  alias MingaAgent.Session
  alias MingaEditor.Agent.ProvenanceJump
  alias MingaEditor.Agent.SessionStart
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.InlineAsk
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent

  @timeout_ms 15_000

  @typedoc "The follow-up work itself, as the start request carried it."
  @type work ::
          {:restore, String.t(), String.t() | nil, ProvenanceJump.origin() | nil,
           UIState.View.return_target()}
          | {:seed, [{:user | :assistant, String.t()}]}

  @typedoc "`{:awaiting, timer}` until the reply or the deadline; `:overdue` after the deadline reported it."
  @type phase :: {:awaiting, reference()} | :overdue

  @type t :: %__MODULE__{
          token: reference(),
          request: :gen_server.request_id(),
          workspace: non_neg_integer(),
          session: pid(),
          work: work(),
          phase: phase()
        }

  @enforce_keys [:token, :request, :workspace, :session, :work, :phase]
  defstruct @enforce_keys

  @doc "Sends the follow-up for `session`, now bound to the agent workspace `workspace_id`, and returns at once."
  @spec run(EditorState.t(), non_neg_integer(), pid(), SessionStart.follow_up()) ::
          EditorState.t()
  def run(state, _workspace_id, _session, nil), do: state

  def run(state, workspace_id, session, {:restore, saved_id, _tool_call, _origin, _return} = work)
      when is_pid(session) do
    case admit_restore(state, workspace_id, saved_id) do
      :ok ->
        track(state, workspace_id, session, work, Session.request_load_session(session, saved_id))

      {:error, %EditorState{} = preserved} ->
        preserved
    end
  end

  def run(state, workspace_id, session, {:seed, messages} = work) when is_pid(session),
    do:
      track(state, workspace_id, session, work, Session.request_seed_messages(session, messages))

  @doc "Handles a follow-up reply or request monitor without intercepting unrelated messages."
  @spec response(EditorState.t(), term()) :: {:handled, EditorState.t()} | :unrelated
  def response(%EditorState{agent_connection: %{session_follow_ups: follow_ups}} = state, message) do
    Enum.find_value(follow_ups, :unrelated, fn {_token, follow_up} ->
      case :gen_server.check_response(message, follow_up.request) do
        :no_reply -> nil
        reply -> {:handled, settle(state, follow_up, reply)}
      end
    end)
  end

  @doc "Reports a follow-up the session has not answered by its deadline; a later reply still settles it."
  @spec timeout(EditorState.t(), reference()) :: EditorState.t()
  def timeout(%EditorState{agent_connection: %{session_follow_ups: follow_ups}} = state, token) do
    case Map.get(follow_ups, token) do
      %__MODULE__{phase: {:awaiting, _timer}} = follow_up ->
        state
        |> EditorState.track_agent_session_follow_up(%{follow_up | phase: :overdue})
        |> NoticeWorkflow.publish(overdue_message(follow_up.work))

      _settled_or_overdue ->
        state
    end
  end

  # The draft guard reads the live Agent UI, which only the workspace in front has.
  @spec admit_restore(EditorState.t(), non_neg_integer(), String.t()) ::
          :ok | {:error, EditorState.t()}
  defp admit_restore(state, workspace_id, saved_id) do
    if active_workspace?(state, workspace_id),
      do: MingaEditor.Agent.DraftWorkflow.before_reopen(state, saved_id),
      else: :ok
  end

  @spec track(EditorState.t(), non_neg_integer(), pid(), work(), :gen_server.request_id()) ::
          EditorState.t()
  defp track(state, workspace_id, session, work, request) do
    token = make_ref()
    timer = Process.send_after(self(), {:agent_session_follow_up_timeout, token}, @timeout_ms)

    EditorState.track_agent_session_follow_up(state, %__MODULE__{
      token: token,
      request: request,
      workspace: workspace_id,
      session: session,
      work: work,
      phase: {:awaiting, timer}
    })
  end

  @spec settle(EditorState.t(), t(), {:reply, term()} | {:error, {term(), term()}}) ::
          EditorState.t()
  defp settle(state, follow_up, reply) do
    cancel_timer(follow_up.phase)
    state = EditorState.finish_agent_session_follow_up(state, follow_up.token)

    case reply do
      {:reply, result} ->
        answered(state, follow_up, result)

      {:error, {_reason, _session}} ->
        NoticeWorkflow.publish(state, exited_message(follow_up.work))
    end
  end

  @spec answered(EditorState.t(), t(), :ok | {:error, term()}) :: EditorState.t()
  defp answered(
         state,
         %__MODULE__{work: {:restore, saved_id, tool_call, origin, return}} = follow_up,
         result
       ) do
    case AgentCommands.restore_outcome(result, saved_id) do
      :ok ->
        if shown?(state, follow_up),
          do:
            AgentCommands.show_restored_session(
              state,
              follow_up.session,
              saved_id,
              tool_call,
              origin,
              return
            ),
          else: state

      {:error, reason} ->
        report_in_session(state, follow_up.session, AgentCommands.restore_failure_message(reason))
    end
  end

  defp answered(state, %__MODULE__{work: {:seed, _messages}} = follow_up, :ok),
    do: InlineAsk.show_seeded_session(state, follow_up.session)

  defp answered(state, %__MODULE__{work: {:seed, _messages}} = follow_up, {:error, reason}),
    do: report_in_session(state, follow_up.session, InlineAsk.seed_failure_message(reason))

  # The failure appears in the conversation of the tab that asked for the work, in front or not.
  @spec report_in_session(EditorState.t(), pid(), String.t()) :: EditorState.t()
  defp report_in_session(state, session, message) do
    Minga.Log.warning(:agent, "[Agent] #{message}")
    Session.add_system_message(session, message, :error)
    state
  end

  # The restored conversation is shown in place only while its workspace is in front with this session.
  @spec shown?(EditorState.t(), t()) :: boolean()
  defp shown?(state, %__MODULE__{workspace: workspace_id, session: session}) do
    case tab_bar(state) do
      %TabBar{} = tabs ->
        TabBar.active_workspace_id(tabs) == workspace_id and
          match?(
            %Workspace{payload: %WorkspaceAgent{session: ^session}},
            TabBar.get_workspace(tabs, workspace_id)
          )

      nil ->
        false
    end
  end

  @spec overdue_message(work()) :: String.t()
  defp overdue_message({:restore, _id, _tool_call, _origin, _return}),
    do: "The saved Agent session has not loaded after 15 seconds."

  defp overdue_message({:seed, _messages}),
    do: "Inline Ask history has not been added to the agent session after 15 seconds."

  @spec exited_message(work()) :: String.t()
  defp exited_message({:restore, _id, _tool_call, _origin, _return}),
    do: AgentCommands.restore_failure_message(:session_unavailable)

  defp exited_message({:seed, _messages}),
    do: "The agent session stopped before Inline Ask history was added."

  @spec active_workspace?(EditorState.t(), non_neg_integer()) :: boolean()
  defp active_workspace?(state, workspace_id) do
    case tab_bar(state) do
      %TabBar{} = tabs -> TabBar.active_workspace_id(tabs) == workspace_id
      nil -> false
    end
  end

  @spec tab_bar(EditorState.t()) :: TabBar.t() | nil
  defp tab_bar(%EditorState{shell_runtime: %{state: %TraditionalState{} = shell}}),
    do: TraditionalState.tab_bar(shell)

  defp tab_bar(%EditorState{}), do: nil

  @spec cancel_timer(phase()) :: :ok
  defp cancel_timer({:awaiting, timer}) do
    Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp cancel_timer(:overdue), do: :ok
end
