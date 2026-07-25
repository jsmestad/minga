defmodule MingaEditor.Agent.Compaction do
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent

  @moduledoc """
  Typed agent-session compaction owned by the agent presentation domain.

  The session pid is both immutable execution input and stable scheduler
  resource identity. A zero-queue FIFO policy admits at most one compaction for
  that session, preserving request order without an unbounded backlog. The
  scheduler runs `run/1` under its generation-owned `Task.Supervisor`; no raw
  task or compact-result mailbox protocol is involved.

  Outcomes are correlated against the workspace that owns the session before
  state changes. Background results update that workspace without touching the
  active UI; removed sessions are reclassified stale. Cancellation clears only
  the matching session's transient progress, and worker/admission
  failures clear progress and surface the existing terminal error toast.
  Successful application adds the system transcript message, synchronizes the
  transcript, and renders through the normal typed-outcome path.
  """

  @behaviour MingaEditor.Effect

  alias MingaEditor.Agent.UIState
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaAgent.Session

  @enforce_keys [:session]
  defstruct [:session]

  @type t :: %__MODULE__{session: pid()}

  @doc "Builds a bounded request keyed by the agent session process."
  @spec request(pid()) :: Request.t()
  def request(session) when is_pid(session) do
    Request.new(%__MODULE__{session: session}, {:agent_session, session}, Policy.fifo(0))
  end

  @doc "Schedules compaction, converting admission failures into domain failure state."
  @spec schedule(EditorState.t(), pid()) :: EditorState.t()
  def schedule(%EditorState{effect_scheduler: nil} = state, session) when is_pid(session) do
    fail_admission(state, request(session), :scheduler_unavailable)
  end

  def schedule(%EditorState{} = state, session) when is_pid(session) do
    request = request(session)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} -> state
      {:error, reason} -> fail_admission(state, request, reason)
    end
  catch
    :exit, reason -> fail_admission(state, request(session), {:scheduler_unavailable, reason})
  end

  @impl true
  @spec run(t()) :: {:ok, String.t()} | {:error, term()}
  def run(%__MODULE__{session: session}) do
    Session.compact(session)
  catch
    :exit, reason -> {:error, {:compact_exit, reason}}
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        %EditorState{} = state,
        %Outcome{request: %{effect: %__MODULE__{} = effect}} = outcome
      ) do
    if MingaEditor.Shell.Runtime.active_session(state.shell_runtime) == effect.session do
      apply_active(state, outcome)
    else
      apply_background(state, outcome, effect.session)
    end
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _payload}})
      when status in [:completed, :failed, :canceled],
      do: true

  def render?(%Outcome{}), do: false

  @spec apply_active(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  defp apply_active(state, %Outcome{value: {:completed, summary}} = outcome)
       when is_binary(summary) do
    Session.add_system_message(
      outcome.request.effect.session,
      "Context auto-compacted: #{summary}"
    )

    state =
      state
      |> update_active_ui(fn ui ->
        ui
        |> clear_ui_progress()
        |> UIState.push_toast("Context compacted", :info)
      end)
      |> AgentLifecycle.sync_transcript()

    {state, outcome}
  end

  defp apply_active(state, %Outcome{value: {:failed, reason}} = outcome) do
    state =
      update_active_ui(state, fn ui ->
        ui
        |> clear_ui_progress()
        |> UIState.push_toast("Auto-compact failed: #{inspect(reason)}", :error)
      end)

    {state, outcome}
  end

  defp apply_active(state, %Outcome{value: {:canceled, _reason}} = outcome) do
    {update_active_ui(state, &clear_ui_progress/1), outcome}
  end

  defp apply_active(state, %Outcome{} = outcome), do: {state, outcome}

  @spec apply_background(EditorState.t(), Outcome.t(), pid()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_background(state, outcome, session) do
    case background_workspace(state, session) do
      %Workspace{id: workspace_id} ->
        {apply_background_outcome(state, workspace_id, session, outcome), outcome}

      nil ->
        {state, Outcome.stale(outcome, :agent_session_changed)}
    end
  end

  @spec apply_background_outcome(EditorState.t(), non_neg_integer(), pid(), Outcome.t()) ::
          EditorState.t()
  defp apply_background_outcome(
         state,
         workspace_id,
         session,
         %Outcome{value: {:completed, summary}}
       )
       when is_binary(summary) do
    Session.add_system_message(session, "Context auto-compacted: #{summary}")

    update_background_ui(state, workspace_id, fn ui ->
      ui
      |> clear_ui_progress()
      |> UIState.push_toast("Context compacted", :info)
    end)
  end

  defp apply_background_outcome(state, workspace_id, _session, %Outcome{
         value: {:failed, reason}
       }) do
    update_background_ui(state, workspace_id, fn ui ->
      ui
      |> clear_ui_progress()
      |> UIState.push_toast("Auto-compact failed: #{inspect(reason)}", :error)
    end)
  end

  defp apply_background_outcome(state, workspace_id, _session, %Outcome{
         value: {:canceled, _reason}
       }) do
    update_background_ui(state, workspace_id, &clear_ui_progress/1)
  end

  defp apply_background_outcome(state, _workspace_id, _session, %Outcome{}), do: state

  @spec update_active_ui(EditorState.t(), (UIState.t() -> UIState.t())) :: EditorState.t()
  defp update_active_ui(state, fun),
    do:
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
        state,
        fun.(state.workspace.agent_ui)
      )

  @spec update_background_ui(EditorState.t(), non_neg_integer(), (UIState.t() -> UIState.t())) ::
          EditorState.t()
  defp update_background_ui(state, workspace_id, fun) do
    tab_bar = state.shell_runtime.state.tab_bar

    workspace = TabBar.get_workspace(tab_bar, workspace_id)
    workspace = Workspace.set_agent_ui(workspace, fun.(background_agent_ui(workspace)))
    tab_bar = TabBar.accept_workspace(tab_bar, workspace)

    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        tab_bar
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  @spec background_agent_ui(Workspace.t() | nil) :: UIState.t()
  defp background_agent_ui(%Workspace{payload: %WorkspaceAgent{agent_ui: %UIState{} = agent_ui}}),
    do: agent_ui

  defp background_agent_ui(_workspace), do: UIState.new()

  @spec background_workspace(EditorState.t(), pid()) :: Workspace.t() | nil
  defp background_workspace(state, session) do
    case state.shell_runtime.state.tab_bar do
      %TabBar{} = tab_bar -> TabBar.find_workspace_by_session(tab_bar, session)
      nil -> nil
    end
  end

  @spec clear_ui_progress(UIState.t()) :: UIState.t()
  defp clear_ui_progress(%UIState{} = ui), do: UIState.finish_compaction(ui)

  @spec fail_admission(EditorState.t(), Request.t(), term()) :: EditorState.t()
  defp fail_admission(state, request, reason) do
    {state, outcome} =
      __MODULE__.apply(state, Outcome.failed(request, {:admission_failed, reason}))

    if render?(outcome), do: MingaEditor.schedule_render(state, 16), else: state
  end
end
