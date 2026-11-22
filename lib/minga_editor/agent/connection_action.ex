defmodule MingaEditor.Agent.ConnectionAction do
  @moduledoc """
  Executes model selection, connection retry, exact cancellation, and model route checks outside the Editor.

  Every request retains the offered workspace and Session target. Session validates the target at the mutation boundary; canonical connection events update presentation. Results never optimistically install a model or restore focus to a workspace the user left.
  """

  @behaviour MingaEditor.Effect

  alias MingaAgent.ModelSelection
  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionTarget
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent

  @type intent ::
          {:model, String.t() | ModelSelection.t()}
          | :retry
          | {:cancel, reference()}
          | {:check_route, route_id :: String.t(), short_name :: String.t()}
  @type t :: %__MODULE__{
          workspace_id: non_neg_integer(),
          target: ConnectionTarget.t(),
          intent: intent()
        }

  @enforce_keys [:workspace_id, :target, :intent]
  defstruct [:workspace_id, :target, :intent]
  @doc "Captures the current owning workspace and canonical connection without querying Session."
  @spec origin(EditorState.t()) ::
          {:ok, non_neg_integer(), MingaAgent.Session.ConnectionSnapshot.t()}
          | {:error, :connection_unavailable}
  def origin(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tab_bar}}} = state) do
    case {TabBar.active_workspace(tab_bar), state.workspace.agent_ui.connection} do
      {%Workspace{id: id, payload: %WorkspaceAgent{session: session}},
       %MingaAgent.Session.ConnectionSnapshot{target: %{session: session}} = snapshot} ->
        {:ok, id, snapshot}

      _unavailable ->
        {:error, :connection_unavailable}
    end
  end

  def origin(_state), do: {:error, :connection_unavailable}

  @doc "Captures a command's origin before scheduling its requested mutation."
  @spec schedule_current(EditorState.t(), intent()) :: EditorState.t()
  def schedule_current(state, intent) do
    case origin(state) do
      {:ok, workspace_id, snapshot} ->
        schedule(state, workspace_id, snapshot.target, intent)

      {:error, :connection_unavailable} ->
        NoticeWorkflow.publish(
          state,
          unavailable_message(Runtime.active_session(state.shell_runtime))
        )
    end
  end

  @spec unavailable_message(pid() | nil) :: String.t()
  defp unavailable_message(nil), do: "No agent session; model selection was not changed."

  defp unavailable_message(_session),
    do: "Connection details are unavailable. Reopen the agent workspace."

  @doc "Schedules one explicitly targeted mutation without queuing stale user actions."
  @spec schedule(EditorState.t(), non_neg_integer(), ConnectionTarget.t(), intent()) ::
          EditorState.t()
  def schedule(state, _workspace_id, %ConnectionTarget{session: session} = target, {:cancel, ref})
      when node(session) == node() do
    :ok = Session.request_connection_cancel(session, target, ref)
    state
  end

  def schedule(state, _workspace_id, %ConnectionTarget{session: session}, intent)
      when node(session) != node() and (intent == :retry or elem(intent, 0) == :cancel) do
    NoticeWorkflow.publish(state, "Manage the connection on the host running this agent session.")
  end

  def schedule(state, workspace_id, %ConnectionTarget{} = target, intent) do
    effect = %__MODULE__{workspace_id: workspace_id, target: target, intent: intent}
    request = Request.new(effect, resource(effect), Policy.fifo(0))
    admit(state, request, state.effect_scheduler)
  end

  @impl true
  @spec run(t()) :: {:ok, :applied | {:notice, String.t()}} | {:error, term()}
  def run(%__MODULE__{target: target, intent: intent}) do
    case execute(target, intent) do
      :ok -> {:ok, :applied}
      {:notice, message} -> {:ok, {:notice, message}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{request: %{effect: %__MODULE__{} = effect}} = outcome) do
    case owned_workspace(state, effect) do
      %Workspace{} = workspace -> apply_owned(state, workspace, outcome)
      nil -> {state, Outcome.stale(outcome, :connection_origin_removed)}
    end
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {:failed, _reason}}), do: true
  def render?(%Outcome{value: {:completed, {:notice, _message}}}), do: true
  def render?(%Outcome{}), do: false

  @spec execute(ConnectionTarget.t(), intent()) ::
          :ok | {:notice, String.t()} | {:error, term()}
  defp execute(target, {:model, selection}),
    do: Session.set_model_for_target(target.session, target, selection)

  defp execute(target, :retry), do: Session.retry_connection(target.session, target)

  defp execute(target, {:check_route, route_id, name}) do
    # minga:allow-blocking — runs in ConnectionAction.run/1 under EffectScheduler, not in the Editor
    case Session.check_inference_route(target.session, route_id) do
      {:ok, entry} -> {:notice, route_check_message(name, entry.status)}
      {:error, :not_found} -> {:error, "#{name} is no longer available. Reopen /model."}
      {:error, :unsupported} -> {:error, "#{name} needs the Native agent backend."}
    end
  end

  @spec route_check_message(String.t(), MingaAgent.InferenceRoute.Status.t()) :: String.t()
  defp route_check_message(name, %{availability: {:ready, account}}),
    do: "#{name} is ready: #{account}."

  defp route_check_message(_name, status),
    do: MingaEditor.UI.Picker.AgentModelSource.setup_readiness(status)

  @spec resource(t()) :: term()
  defp resource(%__MODULE__{target: target}), do: {:agent_connection, target.session}

  @spec admit(EditorState.t(), Request.t(), pid() | nil) :: EditorState.t()
  defp admit(state, request, nil), do: fail_admission(state, request)

  defp admit(state, request, scheduler) do
    case EffectScheduler.schedule(scheduler, request) do
      {:ok, _id, _disposition} -> state
      {:error, _reason} -> fail_admission(state, request)
    end
  catch
    :exit, _reason -> fail_admission(state, request)
  end

  @spec fail_admission(EditorState.t(), Request.t()) :: EditorState.t()
  defp fail_admission(state, request) do
    {state, _outcome} = __MODULE__.apply(state, Outcome.failed(request, :scheduler_unavailable))
    MingaEditor.schedule_render(state, 16)
  end

  @spec owned_workspace(EditorState.t(), t()) :: Workspace.t() | nil
  defp owned_workspace(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tab_bar}}}, effect) do
    case TabBar.get_workspace(tab_bar, effect.workspace_id) do
      %Workspace{payload: %WorkspaceAgent{session: session}} = workspace
      when session == effect.target.session ->
        workspace

      _unowned ->
        nil
    end
  end

  defp owned_workspace(_state, _effect), do: nil

  @spec apply_owned(EditorState.t(), Workspace.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  defp apply_owned(state, workspace, %Outcome{value: {:failed, reason}} = outcome) do
    effect = outcome.request.effect
    tab_bar = state.shell_runtime.state.tab_bar

    if TabBar.active_workspace_id(tab_bar) == workspace.id do
      {publish_failure(state, effect.target, reason), outcome}
    else
      ui = workspace.payload.agent_ui
      workspace = Workspace.set_agent_ui(workspace, failure_notice(ui, effect.target, reason))
      tab_bar = TabBar.accept_workspace(tab_bar, workspace)
      shell_state = ShellState.install_tab_bar(Runtime.state(state.shell_runtime), tab_bar)

      {%{
         state
         | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
       }, outcome}
    end
  end

  defp apply_owned(state, workspace, %Outcome{value: {:completed, {:notice, message}}} = outcome) do
    tab_bar = state.shell_runtime.state.tab_bar

    if TabBar.active_workspace_id(tab_bar) == workspace.id do
      {NoticeWorkflow.publish(state, message), outcome}
    else
      ui = UIState.push_toast(workspace.payload.agent_ui, message, :info)
      workspace = Workspace.set_agent_ui(workspace, ui)
      tab_bar = TabBar.accept_workspace(tab_bar, workspace)
      shell_state = ShellState.install_tab_bar(Runtime.state(state.shell_runtime), tab_bar)

      {%{
         state
         | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
       }, outcome}
    end
  end

  defp apply_owned(state, _workspace, outcome), do: {state, outcome}

  @spec publish_failure(EditorState.t(), ConnectionTarget.t(), term()) :: EditorState.t()
  defp publish_failure(
         %{workspace: %{agent_ui: %{connection: %{target: target}}}} = state,
         target,
         reason
       ),
       do: NoticeWorkflow.publish(state, failure_message(reason))

  defp publish_failure(state, _target, _reason), do: state

  @spec failure_notice(UIState.t(), ConnectionTarget.t(), term()) :: UIState.t()
  defp failure_notice(%UIState{connection: %{target: target}} = ui, target, reason),
    do: UIState.push_toast(ui, failure_message(reason), :error)

  defp failure_notice(ui, _target, _reason), do: ui

  @spec failure_message(term()) :: String.t()
  defp failure_message(:scheduler_unavailable),
    do: "Connection action is busy or unavailable. Try again."

  defp failure_message(:session_unavailable),
    do: "The original agent session is unavailable. Reconnect before retrying."

  defp failure_message(:stale_target),
    do: "The conversation or model changed. Reopen the connection menu."

  defp failure_message(:already_committed),
    do: "Credentials were already saved. Cancellation did not undo them."

  defp failure_message(:superseded),
    do: "This connection action was replaced. Reopen the connection menu."

  defp failure_message(reason) when is_binary(reason), do: reason

  defp failure_message(_reason),
    do: "The connection action failed. Reopen the connection menu to retry."
end
