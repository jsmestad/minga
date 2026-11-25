defmodule MingaEditor.Agent.CatalogStartup do
  @moduledoc """
  Runs the model catalog load off the Editor.

  The catalog preloads in the background through `MingaAgent.ModelCatalog` once the first frame is dispatched, so a later open finds it ready. Opening the Agent never waits for it: the tab and composer appear at once, and only the session start request waits for a cold catalog. Restoring a saved conversation still waits for the catalog before it changes tabs.
  """

  @behaviour MingaEditor.Effect

  alias MingaAgent.ModelCatalog
  alias MingaEditor.Agent.ProvenanceJump
  alias MingaEditor.Agent.SessionStart
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest
  alias MingaEditor.Commands.{Agent, AgentSession}
  alias MingaEditor.Effect.{Outcome, Policy, Request}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State.Tab
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:origin, :action]
  defstruct [:origin, :action]

  @typep origin :: {Tab.id() | nil, Tab.group_id() | nil, pid() | nil}
  @type destination :: :absent | {Tab.id(), Tab.group_id(), pid() | nil}
  @type workspace_action ::
          {:toggle, destination()}
          | {:restore, destination(), String.t(), String.t() | nil, ProvenanceJump.origin() | nil}
          | :new
  @type start :: {:start, pos_integer(), boolean(), boolean(), SessionStart.follow_up()}
  @type action :: workspace_action() | start()
  @type t :: %__MODULE__{origin: origin(), action: action()}

  @doc """
  Runs a local Agent action, scheduling the catalog load first only where the action needs it.

  Opening or toggling the Agent runs at once. A session start or a cold restore waits for the catalog in an effect worker.
  """
  @spec continue(EditorState.t(), action()) :: EditorState.t()
  def continue(state, {:start, _workspace, _hooks?, _recover?, _follow_up} = action),
    do: when_catalog_ready(state, action)

  def continue(state, {:restore, {_tab, _workspace, session}, _, _, _} = action)
      when is_pid(session),
      do: resume(state, action)

  def continue(state, {:restore, _destination, _, _, _} = action),
    do: when_catalog_ready(state, action)

  def continue(state, action), do: resume(state, action)

  @spec when_catalog_ready(EditorState.t(), action()) :: EditorState.t()
  defp when_catalog_ready(state, action) do
    if catalog_ready?(state), do: resume(state, action), else: defer(state, action)
  end

  # Reads only the catalog's load epoch, never the catalog itself.
  @spec catalog_ready?(EditorState.t()) :: boolean()
  defp catalog_ready?(state) do
    state.agent_connection.agent_provider_module not in [nil, MingaAgent.Providers.Native] or
      ModelCatalog.loaded?()
  end

  @doc """
  Loads the model catalog in the background after launch.

  `MingaAgent.ModelCatalog` runs the load in a low-priority task, after the first frame is dispatched. A session start that arrives during it joins the same load, and an Agent opened after it finishes starts its session without waiting. Disabled with `config :minga, agent_catalog_preload: false`.
  """
  @spec preload(EditorState.t()) :: EditorState.t()
  def preload(state) do
    if Application.get_env(:minga, :agent_catalog_preload, true) and not catalog_ready?(state),
      do: ModelCatalog.preload()

    state
  end

  @impl true
  @spec run(t()) :: {:ok, :ready} | {:error, :model_catalog_unavailable}
  def run(%__MODULE__{}), do: ModelCatalog.load()

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{} = outcome) do
    log_load_failure(outcome.value)
    settle(state, outcome)
  end

  # The tab shows only a plain sentence, so the raw reason a load failed is
  # kept in the log whether or not a tab still waits for the result.
  @spec log_load_failure(Outcome.value()) :: :ok
  defp log_load_failure({:failed, reason}),
    do: Minga.Log.error(:agent, fn -> "[Agent] Model catalog load failed: #{inspect(reason)}" end)

  defp log_load_failure(_value), do: :ok

  # A start carries the workspace it was requested for, so its outcome is
  # judged by that workspace, not by which tab is active now.
  @spec settle(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  defp settle(
         state,
         %Outcome{request: %{effect: %__MODULE__{action: {:start, _, _, _, _}}}} = outcome
       ),
       do: complete_start(state, outcome)

  defp settle(state, %Outcome{request: %{effect: effect}, value: value} = outcome) do
    current? = origin(state) == effect.origin and destination_current?(state, effect.action)

    case {current?, value} do
      {true, {:completed, :ready}} -> {resume(state, effect.action), outcome}
      {true, {:failed, _reason}} -> {publish_failure(state, effect.action), outcome}
      {false, {:completed, :ready}} -> {state, Outcome.stale(outcome, :agent_origin_changed)}
      _inactive -> {state, outcome}
    end
  end

  # Only terminal outcomes settle a deferred start. Lifecycle progress
  # (`:running`, `{:queued, _}`) arrives through the same callback while the
  # catalog is still loading and leaves the workspace starting. A canceled or
  # stale start was replaced by a newer request for the same workspace, which
  # owns its result, so it never fails the workspace.
  @spec complete_start(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  defp complete_start(state, %Outcome{request: %{effect: effect}, value: value} = outcome) do
    case start_result(effect.action, value) do
      nil -> {state, outcome}
      result -> settle_start(state, effect.action, result, outcome)
    end
  end

  @spec start_result(start(), Outcome.value()) :: AgentSession.catalog_start_result() | nil
  defp start_result({:start, _workspace, hooks?, recover?, follow_up}, {:completed, :ready}),
    do: {:ready, hooks?, recover?, follow_up}

  defp start_result({:start, _, hooks?, recover?, follow_up}, {:failed, _reason}),
    do: {:failed, catalog_failure(hooks?, recover?, follow_up)}

  defp start_result({:start, _, _, _, _}, _progress_or_replaced), do: nil

  @spec settle_start(EditorState.t(), start(), AgentSession.catalog_start_result(), Outcome.t()) ::
          {EditorState.t(), Outcome.t()}
  defp settle_start(state, {:start, workspace, _, _, follow_up}, result, outcome) do
    case AgentSession.complete_deferred_start(state, workspace, result) do
      {:ok, next} ->
        {next, outcome}

      # A task the drawer started whose workspace is gone did not start; its row says so.
      :stale ->
        state =
          MingaEditor.Agent.TaskWorkflow.start_failed(state, follow_up, "Agent could not start")

        {state, Outcome.stale(outcome, :agent_origin_changed)}
    end
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _}}) when status in [:completed, :failed], do: true
  def render?(%Outcome{}), do: false

  @spec origin(EditorState.t()) :: origin()
  defp origin(%EditorState{shell_runtime: %Runtime{} = runtime}) do
    case Runtime.active_tab(runtime) do
      %Tab{id: id, group_id: group} -> {id, group, Runtime.active_session(runtime)}
      nil -> {nil, nil, nil}
    end
  end

  defp origin(%EditorState{}), do: {nil, nil, nil}

  @doc "Schedules a data-only action for this editor generation."
  @spec defer(EditorState.t(), action()) :: EditorState.t()
  def defer(%{effect_scheduler: nil} = state, action), do: publish_failure(state, action)

  def defer(state, action) do
    effect = %__MODULE__{origin: origin(state), action: action}
    request = Request.new(effect, resource(effect), Policy.latest_wins())

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _id, _disposition} -> NoticeWorkflow.publish(state, "Loading Agent model catalog…")
      {:error, _reason} -> publish_failure(state, action)
    end
  catch
    :exit, _reason -> publish_failure(state, action)
  end

  @spec resource(t()) :: Request.resource()
  defp resource(%__MODULE__{action: {:start, workspace, _, _, _}}),
    do: {:agent_catalog_session_start, workspace}

  defp resource(%__MODULE__{}), do: :agent_catalog_startup

  @spec destination_current?(EditorState.t(), action()) :: boolean()
  defp destination_current?(state, {:toggle, destination}),
    do: Agent.catalog_destination(state) == destination

  defp destination_current?(state, {:restore, destination, _, _, _}),
    do: Agent.catalog_destination(state) == destination

  defp destination_current?(_state, _action), do: true

  @spec resume(EditorState.t(), action()) :: EditorState.t()
  defp resume(state, {:start, workspace, hooks?, recover?, follow_up}),
    do: AgentSession.start_catalog_ready(state, workspace, hooks?, recover?, follow_up)

  defp resume(state, action), do: Agent.resume_catalog_action(state, action)

  @spec publish_failure(EditorState.t(), action()) :: EditorState.t()
  defp publish_failure(state, {:start, workspace, hooks?, recover?, follow_up}) do
    AgentSession.workspace_start_failed(
      state,
      workspace,
      catalog_failure(hooks?, recover?, follow_up)
    )
  end

  defp publish_failure(state, _action) do
    NoticeWorkflow.publish(
      state,
      "Could not load the Agent model catalog. Try opening Agent again."
    )
  end

  @spec catalog_failure(boolean(), boolean(), SessionStart.follow_up()) :: StartFailure.t()
  defp catalog_failure(hooks?, recover?, follow_up),
    do: StartFailure.catalog_unavailable(StartRequest.new(hooks?, recover?, follow_up))
end
