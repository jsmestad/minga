defmodule MingaEditor.Agent.SessionFollowUp do
  @moduledoc """
  Work the Editor sent to an Agent session and has not seen answered.

  Three kinds of work restore or seed a conversation: Restore loads a saved conversation into the Agent tab, the Sessions picker reopens one, and an Inline Ask promote seeds its answered history into the session that started for it. A session may still be starting its provider and handles a call only after that, so the Editor never calls the session for this work. It sends one `:gen_server.send_request/2` and keeps this record until the reply arrives. The request monitors the session, so a session that exits answers with its exit.

  A Restore that loaded is shown with the session's model selection, read by a second request. A Restore or reopen runs whether or not its workspace is in front. Its view changes apply only when the workspace is in front with the same session; a workspace in the background shows the conversation through its arrival when the user returns.

  A Restore failure is shown in a notice while its workspace is in front, and in that session's conversation while it is in the background. A session that exits, or does not answer before the deadline, is reported in a notice because the session cannot show it. A reply after the deadline still settles the work. These functions return the next state; the Editor schedules the render.
  """

  alias MingaAgent.ModelSelection
  alias MingaAgent.Session
  alias MingaEditor.Agent.ProvenanceJump
  alias MingaEditor.Agent.SessionStart
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.InlineAsk
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.UI.Picker.AgentSessionSource

  @timeout_ms 15_000

  @typedoc "Restore loads a saved conversation; it is shown with its view and provenance jump."
  @type restore ::
          {:restore, String.t(), String.t() | nil, ProvenanceJump.origin() | nil,
           UIState.View.return_target()}

  @typedoc "Work a session start can carry until the session binds."
  @type work :: restore() | {:seed, [{:user | :assistant, String.t()}]}

  @typedoc "A Sessions picker reopen of a saved record, guarded by the conversation the picker showed."
  @type reopen ::
          {:reopen, String.t(), String.t(), AgentSessionSource.saved_kind()}

  @typedoc "Work in flight: started work, a picker reopen, or a loaded Restore reading its model selection."
  @type pending :: work() | reopen() | {:restored, restore()}

  @typedoc "`{:awaiting, timer}` until the reply or the deadline; `:overdue` after the deadline reported it."
  @type phase :: {:awaiting, reference()} | :overdue

  @type t :: %__MODULE__{
          token: reference(),
          request: :gen_server.request_id(),
          workspace: non_neg_integer(),
          session: pid(),
          work: pending(),
          phase: phase()
        }

  @enforce_keys [:token, :request, :workspace, :session, :work, :phase]
  defstruct @enforce_keys

  @doc """
  Sends `work` to `session`, bound to the agent workspace `workspace_id`, and returns at once.

  A Restore first checks the draft of a workspace in front. A picker reopen arrives already checked.
  """
  @spec run(EditorState.t(), non_neg_integer(), pid(), SessionStart.follow_up() | reopen()) ::
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

  def run(state, workspace_id, session, {:reopen, saved_id, origin_id, :legacy_import} = work)
      when is_pid(session) do
    request = Session.request_import_legacy_session(session, saved_id, origin_id)
    track(state, workspace_id, session, work, request)
  end

  def run(state, workspace_id, session, {:reopen, saved_id, origin_id, _kind} = work)
      when is_pid(session),
      do:
        track(
          state,
          workspace_id,
          session,
          work,
          Session.request_load_session(session, saved_id, origin_id)
        )

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
    if Runtime.active_workspace?(state.shell_runtime, workspace_id),
      do: MingaEditor.Agent.DraftWorkflow.before_reopen(state, saved_id),
      else: :ok
  end

  @spec track(EditorState.t(), non_neg_integer(), pid(), pending(), :gen_server.request_id()) ::
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
        exited(state, follow_up)
    end
  end

  @spec exited(EditorState.t(), t()) :: EditorState.t()
  defp exited(state, %__MODULE__{work: {:reopen, saved_id, _origin_id, kind}} = follow_up),
    do:
      AgentSessionSource.reopened(
        state,
        follow_up.session,
        saved_id,
        kind,
        {:error, :stale_session}
      )

  defp exited(state, %__MODULE__{work: work}),
    do: NoticeWorkflow.publish(state, exited_message(work))

  @spec answered(EditorState.t(), t(), term()) :: EditorState.t()
  defp answered(
         state,
         %__MODULE__{work: {:restore, saved_id, _, _, _} = restore} = follow_up,
         result
       ) do
    case AgentCommands.restore_outcome(result, saved_id) do
      :ok ->
        if shown?(state, follow_up),
          do:
            track(
              state,
              follow_up.workspace,
              follow_up.session,
              {:restored, restore},
              Session.request_model_selection(follow_up.session)
            ),
          else: state

      {:error, reason} ->
        report_restore_failure(state, follow_up, AgentCommands.restore_failure_message(reason))
    end
  end

  defp answered(state, %__MODULE__{work: {:restored, restore}} = follow_up, selection) do
    if shown?(state, follow_up),
      do:
        AgentCommands.show_restored_session(
          state,
          follow_up.session,
          restore,
          model_selection(selection)
        ),
      else: state
  end

  defp answered(
         state,
         %__MODULE__{work: {:reopen, saved_id, _origin_id, kind}} = follow_up,
         result
       ) do
    if result == :ok and not shown?(state, follow_up),
      do: state,
      else: AgentSessionSource.reopened(state, follow_up.session, saved_id, kind, result)
  end

  defp answered(state, %__MODULE__{work: {:seed, _messages}} = follow_up, :ok),
    do: InlineAsk.show_seeded_session(state, follow_up.session)

  defp answered(state, %__MODULE__{work: {:seed, _messages}} = follow_up, {:error, reason}),
    do: report_in_session(state, follow_up.session, InlineAsk.seed_failure_message(reason))

  # A workspace in front shows the failure at once; one in the background keeps it in its conversation.
  @spec report_restore_failure(EditorState.t(), t(), String.t()) :: EditorState.t()
  defp report_restore_failure(state, follow_up, message) do
    if shown?(state, follow_up),
      do: NoticeWorkflow.publish(state, message),
      else: report_in_session(state, follow_up.session, message)
  end

  @spec model_selection(term()) :: ModelSelection.t() | nil
  defp model_selection(%ModelSelection{} = selection), do: selection
  defp model_selection(_none), do: nil

  # The failure appears in the conversation of the tab that asked for the work.
  @spec report_in_session(EditorState.t(), pid(), String.t()) :: EditorState.t()
  defp report_in_session(state, session, message) do
    Minga.Log.warning(:agent, "[Agent] #{message}")
    Session.add_system_message(session, message, :error)
    state
  end

  # The restored conversation is shown in place only while its workspace is in front with this session.
  @spec shown?(EditorState.t(), t()) :: boolean()
  defp shown?(state, %__MODULE__{workspace: workspace_id, session: session}) do
    case Runtime.traditional_tab_bar(state.shell_runtime) do
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

  @spec overdue_message(pending()) :: String.t()
  defp overdue_message({:restore, _id, _tool_call, _origin, _return}),
    do: "The saved Agent session has not loaded after 15 seconds."

  defp overdue_message({:restored, _restore}),
    do: "The saved Agent session has not loaded after 15 seconds."

  defp overdue_message({:reopen, _id, _origin_id, _kind}),
    do: "Could not confirm that the saved Agent session opened."

  defp overdue_message({:seed, _messages}),
    do: "Inline Ask history has not been added to the agent session after 15 seconds."

  @spec exited_message(work() | {:restored, restore()}) :: String.t()
  defp exited_message({:restore, _id, _tool_call, _origin, _return}),
    do: AgentCommands.restore_failure_message(:session_unavailable)

  defp exited_message({:restored, _restore}),
    do: AgentCommands.restore_failure_message(:session_unavailable)

  defp exited_message({:seed, _messages}),
    do: "The agent session stopped before Inline Ask history was added."

  @spec cancel_timer(phase()) :: :ok
  defp cancel_timer({:awaiting, timer}) do
    Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp cancel_timer(:overdue), do: :ok
end
