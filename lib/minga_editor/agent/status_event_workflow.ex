defmodule MingaEditor.Agent.StatusEventWorkflow do
  @moduledoc """
  Applies agent status and context-pressure events.

  The workflow keeps shell status, tab status, activity, spinner, and compaction state synchronized before rendering. Compaction scheduling remains attached to the active session and runs only after the render request is installed.
  """

  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.Compaction
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.Shell.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace

  @typep compaction_action :: :none | {:compact_session, pid()}

  @doc "Synchronizes a foreground agent status and its dependent UI state."
  @spec status_changed(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  def status_changed(%EditorState{} = state, status) do
    state = transition_status(state, status)
    {state, compaction_action} = apply_pending_auto_compact(state, status)
    state = MingaEditor.schedule_render(state, 16)
    state = log_status(state, status)
    apply_compaction_action(state, compaction_action)
  end

  @doc "Records context usage and applies or defers automatic compaction."
  @spec context_usage(EditorState.t(), non_neg_integer(), non_neg_integer() | nil) ::
          EditorState.t()
  def context_usage(%EditorState{} = state, estimated_tokens, context_limit) do
    state =
      TraditionalWorkflow.install_agent_view(
        state,
        (fn view -> %{view | context_estimate: estimated_tokens} end).(
          state.workspace.agent_ui.view
        )
      )

    {state, compaction_action} = maybe_auto_compact(state, estimated_tokens, context_limit)

    state
    |> MingaEditor.schedule_render(16)
    |> apply_compaction_action(compaction_action)
  end

  @spec transition_status(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp transition_status(state, status) do
    state = TraditionalWorkflow.install_agent_status(state, status)
    state = engage_scroll(state, status)
    state = update_turn_activity(state, status)
    state = update_spinner(state, status)
    state = reset_compact_state(state, status)
    state = sync_tab_agent_status(state, status)
    sync_active_shell_agent_status(state, status)
  end

  @spec engage_scroll(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp engage_scroll(state, :thinking), do: TraditionalWorkflow.engage_agent_scroll(state)
  defp engage_scroll(state, _status), do: state

  @spec update_turn_activity(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp update_turn_activity(state, status) when status in [:thinking, :tool_executing],
    do: update_activity(state, &Activity.start_turn/1)

  defp update_turn_activity(state, status) when status in [:idle, :error, :plan],
    do: update_activity(state, &Activity.finish_turn/1)

  defp update_turn_activity(state, _status), do: state

  @spec update_spinner(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp update_spinner(state, status) when status in [:thinking, :tool_executing],
    do: TraditionalWorkflow.install_agent_spinner_start(state)

  defp update_spinner(state, _status), do: TraditionalWorkflow.install_agent_spinner_stop(state)

  @spec reset_compact_state(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp reset_compact_state(state, :idle) do
    TraditionalWorkflow.install_agent_view(
      state,
      (fn view -> %{view | compact_warned: false, compact_triggered: false} end).(
        state.workspace.agent_ui.view
      )
    )
  rescue
    _error -> state
  end

  defp reset_compact_state(state, _status), do: state

  @spec log_status(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp log_status(state, :error) do
    Minga.Log.info(:editor, "Agent: error")
    state
  end

  defp log_status(state, _status), do: state

  @spec maybe_auto_compact(EditorState.t(), non_neg_integer(), non_neg_integer() | nil) ::
          {EditorState.t(), compaction_action()}
  defp maybe_auto_compact(state, _estimated_tokens, nil), do: {state, :none}
  defp maybe_auto_compact(state, _estimated_tokens, 0), do: {state, :none}

  defp maybe_auto_compact(
         %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state,
         estimated_tokens,
         context_limit
       ) do
    fill_pct = min(round(estimated_tokens / context_limit * 100), 100)
    view = state.workspace.agent_ui.view
    agent_status = TraditionalState.agent(shell_state).runtime.status
    compact_when_ready(state, view, agent_status, fill_pct)
  end

  defp maybe_auto_compact(%EditorState{} = state, _estimated_tokens, _context_limit),
    do: {state, :none}

  @spec compact_when_ready(EditorState.t(), term(), AgentState.status(), non_neg_integer()) ::
          {EditorState.t(), compaction_action()}
  defp compact_when_ready(state, _view, status, fill_pct)
       when status in [:thinking, :tool_executing] do
    state =
      TraditionalWorkflow.install_agent_view(
        state,
        (&%{&1 | compact_pending_fill_pct: fill_pct}).(state.workspace.agent_ui.view)
      )

    {state, :none}
  end

  defp compact_when_ready(state, %{compaction_in_progress: true}, _status, _fill_pct),
    do: {state, :none}

  defp compact_when_ready(state, view, _status, fill_pct),
    do: apply_compact_threshold(state, view, fill_pct)

  @spec apply_pending_auto_compact(EditorState.t(), Tab.agent_status()) ::
          {EditorState.t(), compaction_action()}
  defp apply_pending_auto_compact(state, :idle) do
    case state.workspace.agent_ui.view.compact_pending_fill_pct do
      nil ->
        {state, :none}

      fill_pct ->
        state =
          TraditionalWorkflow.install_agent_view(
            state,
            (&%{&1 | compact_pending_fill_pct: nil}).(state.workspace.agent_ui.view)
          )

        apply_compact_threshold(state, state.workspace.agent_ui.view, fill_pct)
    end
  end

  defp apply_pending_auto_compact(state, _status), do: {state, :none}

  @spec apply_compact_threshold(EditorState.t(), term(), non_neg_integer()) ::
          {EditorState.t(), compaction_action()}
  defp apply_compact_threshold(state, view, fill_pct) do
    compact_threshold_result(
      state,
      view,
      fill_pct,
      compact_auto_threshold(),
      compact_warn_threshold()
    )
  end

  @spec compact_threshold_result(
          EditorState.t(),
          term(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {EditorState.t(), compaction_action()}
  defp compact_threshold_result(state, %{compact_triggered: false}, fill_pct, auto_pct, _warn_pct)
       when auto_pct > 0 and fill_pct >= auto_pct,
       do: trigger_auto_compact(state)

  defp compact_threshold_result(state, %{compact_warned: false}, fill_pct, _auto_pct, warn_pct)
       when warn_pct > 0 and fill_pct >= warn_pct,
       do: warn_context_pressure(state, fill_pct)

  defp compact_threshold_result(state, _view, _fill_pct, _auto_pct, _warn_pct),
    do: {state, :none}

  @spec trigger_auto_compact(EditorState.t()) :: {EditorState.t(), compaction_action()}
  defp trigger_auto_compact(state) do
    case Runtime.active_session(state.shell_runtime) do
      session when is_pid(session) ->
        state =
          TraditionalWorkflow.install_agent_view(
            state,
            (fn view ->
               %{view | compact_triggered: true, compaction_in_progress: true}
             end).(state.workspace.agent_ui.view)
          )

        {state, {:compact_session, session}}

      _session ->
        {state, :none}
    end
  end

  @spec warn_context_pressure(EditorState.t(), non_neg_integer()) ::
          {EditorState.t(), compaction_action()}
  defp warn_context_pressure(state, fill_pct) do
    state =
      TraditionalWorkflow.install_agent_view(
        state,
        (fn view -> %{view | compact_warned: true} end).(state.workspace.agent_ui.view)
      )

    state =
      TraditionalWorkflow.install_agent_ui(
        state,
        (fn ui ->
           UIState.push_toast(
             ui,
             "Context at #{fill_pct}%. Run /compact to free space.",
             :warning
           )
         end).(state.workspace.agent_ui)
      )

    {state, :none}
  end

  @spec compact_warn_threshold() :: non_neg_integer()
  defp compact_warn_threshold do
    case Minga.Config.Options.get(:agent_compaction_threshold) do
      nil -> 0
      threshold when is_number(threshold) -> round(threshold * 100)
      _invalid -> 80
    end
  end

  @spec compact_auto_threshold() :: non_neg_integer()
  defp compact_auto_threshold do
    case compact_warn_threshold() do
      warn when warn > 0 -> min(warn + 10, 100)
      _disabled -> 0
    end
  end

  @spec apply_compaction_action(EditorState.t(), compaction_action()) :: EditorState.t()
  defp apply_compaction_action(state, :none), do: state

  defp apply_compaction_action(state, {:compact_session, session}),
    do: Compaction.schedule(state, session)

  @spec update_activity(EditorState.t(), (Activity.t() -> Activity.t())) :: EditorState.t()
  defp update_activity(state, fun) when is_function(fun, 1) do
    TraditionalWorkflow.install_agent_ui(
      state,
      (fn ui -> UIState.replace_activity(ui, fun.(ui.view.activity)) end).(
        state.workspace.agent_ui
      )
    )
  end

  @spec sync_active_shell_agent_status(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp sync_active_shell_agent_status(state, status) do
    state = Workflow.ensure_available(state)
    session = Runtime.active_session(state.shell_runtime)
    sync_shell_agent_status(state, session, status)
  end

  @spec sync_shell_agent_status(EditorState.t(), pid() | nil, Tab.agent_status()) ::
          EditorState.t()
  defp sync_shell_agent_status(state, session, _status) when not is_pid(session), do: state

  defp sync_shell_agent_status(state, session, status) do
    runtime =
      Runtime.sync_agent_status(
        state.shell_runtime,
        Workflow.resolved_entries(),
        session,
        status
      )

    %{state | shell_runtime: runtime}
  end

  @spec sync_tab_agent_status(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp sync_tab_agent_status(state, status) do
    tab_bar = traditional_tab_bar(state)
    session = Runtime.active_session(state.shell_runtime)
    update_tab_agent_status(state, status, session, tab_bar)
  end

  @spec update_tab_agent_status(
          EditorState.t(),
          Tab.agent_status(),
          pid() | nil,
          TabBar.t() | nil
        ) :: EditorState.t()
  defp update_tab_agent_status(state, _status, _session, nil), do: state

  defp update_tab_agent_status(state, _status, session, _tab_bar) when not is_pid(session),
    do: state

  defp update_tab_agent_status(state, status, session, tab_bar) do
    tab_bar =
      case TabBar.find_workspace_by_session(tab_bar, session) do
        %Workspace{id: workspace_id} ->
          TabBar.set_workspace_agent_status(tab_bar, workspace_id, status)

        nil ->
          tab_bar
      end

    tab_bar =
      case TabBar.find_by_session(tab_bar, session) do
        %Tab{id: tab_id} -> TabBar.set_tab_agent_status(tab_bar, tab_id, status)
        nil -> tab_bar
      end

    install_tab_bar(state, tab_bar)
  end

  @spec traditional_tab_bar(EditorState.t()) :: TabBar.t() | nil
  defp traditional_tab_bar(state) do
    case Runtime.state(state.shell_runtime) do
      %TraditionalState{} = shell_state -> TraditionalState.tab_bar(shell_state)
      _other_shell_state -> nil
    end
  end

  @spec install_tab_bar(EditorState.t(), TabBar.t()) :: EditorState.t()
  defp install_tab_bar(%EditorState{} = state, %TabBar{} = tab_bar) do
    MingaEditor.WorkspaceWorkflow.install_tab_bar(state, tab_bar)
  end
end
