defmodule MingaEditor.Agent.CatalogStartup do
  @moduledoc "Runs the first model catalog load off the editor before continuing a local Agent action."

  @behaviour MingaEditor.Effect

  alias MingaEditor.Agent.ProvenanceJump
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
  @type action :: workspace_action() | {:start, boolean(), boolean()}
  @type t :: %__MODULE__{origin: origin(), action: action()}

  @doc "Runs a ready local Agent action or schedules its catalog load."
  @spec continue(EditorState.t(), action()) :: EditorState.t()
  def continue(state, action) do
    case {state.agent_connection.agent_provider_module, LLMDB.epoch(), action} do
      {_module, _epoch, {:toggle, {_tab, _workspace, session}}} when is_pid(session) ->
        resume(state, action)

      {_module, _epoch, {:restore, {_tab, _workspace, session}, _, _, _}} when is_pid(session) ->
        resume(state, action)

      {module, 0, _action} when module in [nil, MingaAgent.Providers.Native] ->
        defer(state, action)

      _ready ->
        resume(state, action)
    end
  end

  @impl true
  @spec run(t()) :: {:ok, :ready} | {:error, :model_catalog_unavailable}
  def run(%__MODULE__{}) do
    _providers = LLMDB.providers()
    {:ok, :ready}
  rescue
    LLMDB.LoadError -> {:error, :model_catalog_unavailable}
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{request: %{effect: effect}, value: value} = outcome) do
    current? = origin(state) == effect.origin and destination_current?(state, effect.action)

    case {current?, value, effect.action} do
      {true, {:completed, :ready}, _action} ->
        {resume(state, effect.action), outcome}

      {true, {:failed, _reason}, _action} ->
        {publish_failure(state, effect.action), outcome}

      {false, {:completed, :ready}, {:start, hooks?, recover?}} ->
        complete_inactive_start(state, outcome, effect.origin, {:ready, hooks?, recover?})

      {false, {:failed, _reason}, {:start, _hooks?, _recover?}} ->
        complete_inactive_start(state, outcome, effect.origin, {:failed, catalog_failure()})

      {false, {:completed, :ready}, _action} ->
        {state, Outcome.stale(outcome, :agent_origin_changed)}

      _inactive ->
        {state, outcome}
    end
  end

  @spec complete_inactive_start(
          EditorState.t(),
          Outcome.t(),
          origin(),
          AgentSession.catalog_start_result()
        ) :: {EditorState.t(), Outcome.t()}
  defp complete_inactive_start(state, outcome, target, result) do
    case AgentSession.complete_inactive_start(state, target, result) do
      {:ok, next} -> {next, outcome}
      :stale -> {state, Outcome.stale(outcome, :agent_origin_changed)}
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
  defp resource(%__MODULE__{action: {:start, _, _}, origin: {tab, workspace, _}})
       when is_integer(tab) and is_integer(workspace) and workspace > 0,
       do: {:agent_catalog_session_start, tab, workspace}

  defp resource(%__MODULE__{}), do: :agent_catalog_startup

  @spec destination_current?(EditorState.t(), action()) :: boolean()
  defp destination_current?(state, {:toggle, destination}),
    do: Agent.catalog_destination(state) == destination

  defp destination_current?(state, {:restore, destination, _, _, _}),
    do: Agent.catalog_destination(state) == destination

  defp destination_current?(_state, _action), do: true

  @spec resume(EditorState.t(), action()) :: EditorState.t()
  defp resume(state, {:start, hooks?, recover?}),
    do: AgentSession.start_catalog_ready(state, hooks?, recover?)

  defp resume(state, action), do: Agent.resume_catalog_action(state, action)

  @spec publish_failure(EditorState.t(), action()) :: EditorState.t()
  defp publish_failure(state, {:start, _hooks?, _recover?}) do
    AgentSession.startup_failed(state, catalog_failure())
  end

  defp publish_failure(state, _action) do
    NoticeWorkflow.publish(
      state,
      "Could not load the Agent model catalog. Try opening Agent again."
    )
  end

  @spec catalog_failure() :: String.t()
  defp catalog_failure, do: "Could not load the Agent model catalog."
end
