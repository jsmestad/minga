defmodule MingaEditor.Commands.Agent do
  @moduledoc """
  Editor commands for AI agent interaction.

  Handles toggling the agent panel, submitting prompts, scrolling
  the chat, and managing agent sessions. All functions are pure
  `state → state` transformations.
  """

  @behaviour Minga.Command.Provider

  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.FileMention
  alias MingaAgent.Markdown
  alias MingaAgent.Message
  alias MingaAgent.ModelSelection
  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.SessionStore
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.ProvenanceJump
  alias MingaEditor.Agent.SlashCommand
  alias MingaEditor.Agent.StatusEventWorkflow
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Agent.TurnRequest
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Agent.WorkspaceStatus
  alias MingaEditor.Agent.View.Preview
  alias Minga.Buffer
  alias Minga.Clipboard
  alias MingaEditor.Commands
  alias MingaEditor.HighlightSync
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Commands.AgentSubStates

  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Agent.DraftSave
  alias MingaEditor.Agent.DraftWorkflow
  alias MingaEditor.Agent.CatalogStartup
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.TabWorkflow
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.Input.AgentPanel

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @type prompt_readiness ::
          :no_model
          | :credentials_checking
          | :credentials_missing
          | :starting
          | :unavailable
          | {:startup_failed, String.t()}
          | {:start_failed, MingaEditor.Agent.StartFailure.t()}
          | :ready
  @type prompt_submit_status :: :ready | {:blocked, String.t()}

  @doc "Legacy alias for `toggle_agent_split/1`."
  @spec toggle_agentic_view(state()) :: state()
  def toggle_agentic_view(state), do: toggle_agent_split(state)

  @doc """
  Toggles an agent chat split pane in the window tree.

  When no agent pane exists: ensures an agent session is running,
  then applies the `:agent_right` layout preset (file left, agent
  chat right) and focuses the composer in Insert. When an agent pane exists: removes it and restores
  the single-window layout.

  The agent state lives in a background agent tab (created if needed).
  """
  @spec toggle_agent_split(state()) :: state()
  def toggle_agent_split(state) do
    state = ShellWorkflow.ensure_available(state)

    case MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) do
      :agent ->
        return_to_editor(state)

      _ ->
        CatalogStartup.continue(state, {:toggle, catalog_destination(state)})
    end
  end

  @doc "Identifies the current Agent tab and conversation before the model catalog loads."
  @spec catalog_destination(state()) :: CatalogStartup.destination()
  def catalog_destination(state) do
    case find_agent_tab(state) do
      %Tab{id: id, group_id: workspace, payload: %Tab.Agent{session: session}} ->
        {id, workspace, session}

      nil ->
        :absent
    end
  end

  @doc "Runs an Agent workspace action after catalog startup validates its destination."
  @spec resume_catalog_action(state(), CatalogStartup.workspace_action()) :: state()
  def resume_catalog_action(state, {:toggle, _destination}) do
    state = ensure_agent_state(state)
    return_target = build_return_target(state)

    case find_agent_tab(state) do
      %Tab{id: agent_id} ->
        # The conversation opens with the composer focused in Insert, so you can type at once.
        state
        |> measured_tab_switch(agent_id)
        |> maybe_start_session()
        |> activate_agent_view(return_target)
        |> scope_focus_input()

      nil ->
        state
    end
  end

  def resume_catalog_action(state, {:restore, _destination, session_id, tool_call_id, origin}),
    do: open_ready_session(state, session_id, tool_call_id, origin)

  def resume_catalog_action(state, :new), do: new_ready_session(state)

  @doc """
  Opens the agent panel (creating it if needed) and resumes the persisted
  session `session_id` into it, then activates the agent view.

  With a `tool_call_id`, arms a provenance jump so the chat lands on the turn
  that produced that edit (the turn's opening user message) instead of the
  bottom of the conversation, and remembers the source file+line for the
  return trip. Without one, behaves like a plain resume (lands at the bottom).

  Unlike `toggle_agent_split/1` this never closes an open panel; it is the
  entry point for "jump from code into the agent session that wrote it".
  """
  @spec open_session(state(), String.t(), String.t() | nil) :: state()
  def open_session(state, session_id, tool_call_id \\ nil) when is_binary(session_id) do
    state = ShellWorkflow.ensure_available(state)
    origin = capture_origin(state)

    CatalogStartup.continue(
      state,
      {:restore, catalog_destination(state), session_id, tool_call_id, origin}
    )
  end

  @spec open_ready_session(state(), String.t(), String.t() | nil, ProvenanceJump.origin() | nil) ::
          state()
  defp open_ready_session(state, session_id, tool_call_id, origin) do
    state = ensure_agent_tab(state, &find_local_agent_tab/1)
    return_target = build_return_target(state)

    case find_local_agent_tab(state) do
      %Tab{id: agent_id} ->
        state = TabWorkflow.switch(state, agent_id)

        case Runtime.active_session(state.shell_runtime) do
          nil ->
            AgentSession.start_agent_session(state,
              follow_up: {:restore, session_id, tool_call_id, origin, return_target}
            )

          _session ->
            open_session_in_tab(state, session_id, tool_call_id, origin, return_target)
        end

      nil ->
        NoticeWorkflow.publish(state, "Could not open agent")
    end
  end

  @doc """
  Shows a saved conversation that `session` has loaded in the Agent workspace in front.

  `MingaEditor.Agent.SessionFollowUp` runs this once the session has answered the load and its model selection read.
  """
  @spec show_restored_session(
          state(),
          pid(),
          MingaEditor.Agent.SessionFollowUp.restore(),
          ModelSelection.t() | nil
        ) :: state()
  def show_restored_session(
        state,
        session,
        {:restore, session_id, tool_call_id, origin, return_target},
        selection
      )
      when is_pid(session) do
    state
    |> MingaEditor.Agent.Arrival.retire(session)
    |> update_agent_ui(&UIState.reset_edit_timeline/1)
    |> DraftWorkflow.after_reopen(session, session_id)
    |> apply_restored_model_selection(selection)
    |> arm_provenance_jump(tool_call_id, origin)
    |> activate_agent_view(return_target)
  end

  # The bound session may still be starting its provider, so the load is sent without waiting for it.
  @spec open_session_in_tab(
          state(),
          String.t(),
          String.t() | nil,
          ProvenanceJump.origin() | nil,
          UIState.View.return_target()
        ) :: state()
  defp open_session_in_tab(state, session_id, tool_call_id, origin, return_target) do
    case Runtime.active_session(state.shell_runtime) do
      nil ->
        NoticeWorkflow.publish(state, "No agent session available")

      session_pid ->
        MingaEditor.Agent.SessionFollowUp.run(
          state,
          TabBar.active_workspace_id(state.shell_runtime.state.tab_bar),
          session_pid,
          {:restore, session_id, tool_call_id, origin, return_target}
        )
    end
  end

  @doc "Turns a session's answer to a saved-session load into a reason the user may see; raw reasons are logged."
  @spec restore_outcome(:ok | {:error, term()}, String.t()) :: :ok | {:error, atom()}
  def restore_outcome(:ok, _session_id), do: :ok
  def restore_outcome({:error, :legacy_import_required} = error, _session_id), do: error

  def restore_outcome({:error, reason}, session_id) do
    Minga.Log.warning(
      :agent,
      "[Agent.Commands] session #{session_id} restore failed: #{inspect(reason)}"
    )

    {:error, safe_restore_error(reason)}
  end

  @spec safe_restore_error(term()) :: atom()
  defp safe_restore_error(:invalid_session_record), do: :invalid_saved_session

  defp safe_restore_error({:checkpoint_reconciliation_failed, _reason}),
    do: :effect_reconciliation_failed

  defp safe_restore_error({:event_log_reconciliation_failed, _reason}),
    do: :event_log_unavailable

  defp safe_restore_error({:memory_restore_failed, _reason}), do: :memory_restore_failed

  defp safe_restore_error({:provider_model_restore_failed, _reason}), do: :model_restore_failed

  defp safe_restore_error({:restore_rollback_failed, _restore, _rollback}),
    do: :restore_rollback_failed

  defp safe_restore_error(:session_persistence_disabled), do: :session_persistence_disabled
  defp safe_restore_error(:invalid_continuation_boundaries), do: :invalid_saved_session
  defp safe_restore_error(:invalid_continuation), do: :invalid_saved_session
  defp safe_restore_error({:unknown_session_version, _version}), do: :unsupported_session_version

  defp safe_restore_error({:unknown_continuation_version, _version}),
    do: :unsupported_session_version

  defp safe_restore_error({:save_current_failed, _reason}), do: :current_session_save_failed

  defp safe_restore_error({:invalid_continuation_boundaries, _reason}), do: :invalid_saved_session
  defp safe_restore_error({:invalid_continuation, _reason}), do: :invalid_saved_session
  defp safe_restore_error(_reason), do: :restore_failed

  @doc "The sentence that tells the user why a saved session did not open, for a reason from `restore_outcome/2`."
  @spec restore_failure_message(atom()) :: String.t()
  def restore_failure_message(:legacy_import_required),
    do: "This saved session uses a legacy format. Import it before opening."

  def restore_failure_message(:session_unavailable),
    do: "The agent session stopped while loading. The current conversation was not replaced."

  def restore_failure_message(:invalid_saved_session),
    do: "The saved session record is invalid. The current conversation was not replaced."

  def restore_failure_message(:effect_reconciliation_failed),
    do:
      "Interrupted tool work could not be reconciled safely. The current conversation was not replaced."

  def restore_failure_message(:event_log_unavailable),
    do:
      "The session effect log could not be read during recovery. The current conversation was not replaced."

  def restore_failure_message(:memory_restore_failed),
    do: "Session memory could not be restored. The current conversation was not replaced."

  def restore_failure_message(:model_restore_failed),
    do: "The saved model could not be restored. The current conversation was not replaced."

  def restore_failure_message(:restore_rollback_failed),
    do:
      "Session restore failed and provider rollback also failed. Restart the session before continuing."

  def restore_failure_message(:session_persistence_disabled),
    do: "Interrupted work needs durable storage before restore can continue."

  def restore_failure_message(:unsupported_session_version),
    do: "This session was saved by a newer format. The current conversation was not replaced."

  def restore_failure_message(:current_session_save_failed),
    do: "The current conversation could not be saved before restore. It was not replaced."

  def restore_failure_message(:restore_failed),
    do: "Could not restore the saved session. The current conversation was not replaced."

  # Source file + cursor line the user jumped from, for the return trip.
  @spec capture_origin(state()) :: ProvenanceJump.origin() | nil
  defp capture_origin(%{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    with path when is_binary(path) <- safe_file_path(buf),
         {line, _col} <- safe_cursor(buf) do
      {path, line}
    else
      _ -> nil
    end
  end

  defp capture_origin(_state), do: nil

  @spec arm_provenance_jump(state(), String.t() | nil, ProvenanceJump.origin() | nil) :: state()
  defp arm_provenance_jump(state, nil, _origin), do: state

  defp arm_provenance_jump(state, tool_call_id, origin) do
    jump = ProvenanceJump.request({:tool_call_id, tool_call_id}, origin)
    panel = Panel.set_provenance_jump(state.workspace.agent_ui.panel, jump)
    TraditionalWorkflow.install_agent_panel(state, panel)
  end

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(buf) do
    Buffer.file_path(buf)
  catch
    :exit, _ -> nil
  end

  @spec safe_cursor(pid()) :: {non_neg_integer(), non_neg_integer()} | nil
  defp safe_cursor(buf) do
    Buffer.cursor(buf)
  catch
    :exit, _ -> nil
  end

  @spec ensure_agent_state(state()) :: state()
  defp ensure_agent_state(state), do: ensure_agent_tab(state)

  @spec ensure_agent_tab(state(), (state() -> Tab.t() | nil)) :: state()
  defp ensure_agent_tab(state, find \\ &find_agent_tab/1) do
    case find.(state) do
      nil ->
        tab_bar = state.shell_runtime.state.tab_bar || TabBar.new(Tab.new_file(1, "File"))

        {tb, new_tab} =
          TabWorkflow.insert_agent(
            tab_bar,
            "Agent",
            state.frontend.terminal_viewport,
            state.workspace.file_tree.project_root
          )

        install_owned_agent_tab(state, tb, new_tab.id)

      %Tab{id: id, group_id: 0} ->
        install_owned_agent_tab(state, state.shell_runtime.state.tab_bar, id)

      _existing ->
        state
    end
  end

  @spec install_owned_agent_tab(state(), TabBar.t(), Tab.id()) :: state()
  defp install_owned_agent_tab(state, tab_bar, tab_id) do
    {tabs, workspace} = TabBar.add_workspace(tab_bar, "Agent")
    tabs = TabBar.move_tab_to_workspace(tabs, tab_id, workspace.id)
    MingaEditor.WorkspaceWorkflow.install_tab_bar(state, tabs)
  end

  @doc """
  Cycles through agent tabs. If no agent tabs exist, creates one.
  Currently delegates to toggle_agent_split since there's one agent
  session. Multi-agent tab cycling is future work.
  """
  @spec cycle_agent_tabs(state()) :: state()
  def cycle_agent_tabs(state), do: toggle_agent_split(state)

  @spec find_agent_tab(state()) :: Tab.t() | nil
  defp find_agent_tab(%{shell_runtime: %{state: %{tab_bar: nil}}}), do: nil

  defp find_agent_tab(%{shell_runtime: %{state: %{tab_bar: tb}}}),
    do: TabBar.find_by_kind(tb, :agent)

  # A saved conversation loads only into a session on this node, so a restore never picks a remote Agent tab.
  @spec find_local_agent_tab(state()) :: Tab.t() | nil
  defp find_local_agent_tab(%{shell_runtime: %{state: %{tab_bar: %TabBar{tabs: tabs}}}}),
    do:
      Enum.find(
        tabs,
        &match?(%Tab{kind: :agent, payload: %Tab.Agent{remote_session_id: nil}}, &1)
      )

  defp find_local_agent_tab(_state), do: nil

  # Starts an agent session after switching into the agent tab.
  # Called only after the tab switch so Shell.Runtime.active_session/1 sees the tab's pid.
  @spec maybe_start_session(state()) :: state()
  defp maybe_start_session(state) do
    if Runtime.active_session(state.shell_runtime) == nil do
      AgentSession.start_agent_session(state)
    else
      state
    end
  end

  @spec build_return_target(state()) :: UIState.View.return_target()
  defp build_return_target(state) do
    active_tab_id = active_tab_id(state)

    UIState.return_target(
      active_tab_id,
      state.workspace.buffers.active,
      state.workspace.windows,
      state.workspace.file_tree,
      state.workspace.keymap_scope,
      state.workspace.agent_ui.panel.input_focused
    )
  end

  @spec active_tab_id(state()) :: pos_integer() | nil
  defp active_tab_id(state) do
    case MingaEditor.Shell.Runtime.active_tab(state.shell_runtime) do
      %Tab{id: id} -> id
      nil -> nil
    end
  end

  @spec activate_agent_view(state(), UIState.View.return_target()) :: state()
  defp activate_agent_view(state, return_target) do
    update_agent_ui(
      state,
      &UIState.activate(&1, return_target.windows, return_target.file_tree, return_target)
    )
  end

  @doc "Reveals an already resolved Agent tab without toggling it or starting a session."
  @spec reveal_agent_view(state(), Tab.id()) :: state()
  def reveal_agent_view(state, agent_tab_id) do
    state = ShellWorkflow.ensure_available(state)
    tab_bar = Runtime.state(state.shell_runtime).tab_bar

    case {TabBar.get(tab_bar, agent_tab_id), Runtime.active_tab(state.shell_runtime)} do
      {%Tab{kind: :agent}, %Tab{id: ^agent_tab_id}} ->
        TabWorkflow.switch(state, agent_tab_id)

      {%Tab{kind: :agent}, _current} ->
        return_target = build_return_target(state)

        state
        |> TabWorkflow.switch(agent_tab_id)
        |> activate_agent_view(return_target)

      {_missing, _current} ->
        NoticeWorkflow.publish(state, "Agent review workspace is no longer available")
    end
  end

  @doc "Returns from the agent view to the recorded editor context without stopping the session. If no file tab or recorded context exists, keeps the agent view active and reports the unavailable target."
  @spec return_to_editor(state()) :: state()
  def return_to_editor(state) do
    state = ShellWorkflow.ensure_available(state)
    return_target = state.workspace.agent_ui.view |> UIState.View.return_target()

    case target_file_tab_id(state.shell_runtime.state.tab_bar, return_target) do
      {:exact, id} ->
        state
        |> mark_agent_view_inactive()
        |> TabWorkflow.switch(id)
        |> restore_return_keymap_scope(return_target)

      {:fallback, id} ->
        state
        |> mark_agent_view_inactive()
        |> TabWorkflow.switch(id)

      :home ->
        TabWorkflow.leave_to_home(state)

      nil ->
        restore_return_target_without_tab(state, return_target)
    end
  end

  @spec target_file_tab_id(TabBar.t() | nil, UIState.View.return_target() | nil) ::
          {:exact, pos_integer()} | {:fallback, pos_integer()} | :home | nil
  # Opened from the project home (no tab active): leaving goes back to the home, even with file tabs behind it.
  defp target_file_tab_id(%TabBar{}, %{active_tab_id: nil}), do: :home

  defp target_file_tab_id(%TabBar{} = tb, %{active_tab_id: id}) when is_integer(id) do
    case TabBar.get(tb, id) do
      %Tab{kind: :file, id: file_id} -> {:exact, file_id}
      _ -> fallback_file_tab_id(tb)
    end
  end

  defp target_file_tab_id(%TabBar{} = tb, _return_target), do: fallback_file_tab_id(tb)
  defp target_file_tab_id(_tb, _return_target), do: nil

  @spec fallback_file_tab_id(TabBar.t()) :: {:fallback, pos_integer()} | nil
  defp fallback_file_tab_id(%TabBar{} = tb) do
    case TabBar.most_recent_of_kind(tb, :file) do
      %Tab{id: id} -> {:fallback, id}
      nil -> nil
    end
  end

  @spec restore_return_keymap_scope(state(), UIState.View.return_target() | nil) :: state()
  defp restore_return_keymap_scope(state, %{keymap_scope: keymap_scope}) do
    %{
      state
      | workspace: MingaEditor.Session.State.set_keymap_scope(state.workspace, keymap_scope)
    }
  end

  defp restore_return_keymap_scope(state, _return_target) do
    %{state | workspace: MingaEditor.Session.State.set_keymap_scope(state.workspace, :editor)}
  end

  @spec restore_return_target_without_tab(state(), UIState.View.return_target() | nil) :: state()
  # A task started from the project home has no file to return to.
  # Leaving it returns to the home, where the task keeps running and is listed.
  defp restore_return_target_without_tab(state, nil),
    do: TabWorkflow.leave_to_home(state)

  defp restore_return_target_without_tab(state, return_target) do
    state
    |> mark_agent_view_inactive()
    |> restore_workspace_return_target(return_target)
    |> restore_prompt_focus(return_target.prompt_focused)
    |> NoticeWorkflow.publish("No file tabs in this workspace")
  end

  @spec restore_workspace_return_target(state(), UIState.View.return_target()) :: state()
  defp restore_workspace_return_target(state, return_target) do
    old_buffer = state.workspace.buffers.active

    workspace =
      state.workspace
      |> SessionState.set_keymap_scope(return_target.keymap_scope)
      |> SessionState.set_windows(return_target.windows)
      |> SessionState.set_file_tree(return_target.file_tree)
      |> restore_return_target_buffer(return_target.active_buffer)

    %{state | workspace: workspace}
    |> HighlightSync.ensure_active_buffer_presentation(old_buffer)
  end

  @spec restore_return_target_buffer(SessionState.t(), pid() | nil) :: SessionState.t()
  defp restore_return_target_buffer(workspace, active_buffer) when is_pid(active_buffer) do
    buffers = Buffers.switch_to_pid(workspace.buffers, active_buffer)

    buffers =
      if buffers.active == active_buffer do
        buffers
      else
        Buffers.replace_list(buffers, [active_buffer | buffers.list], 0)
      end

    SessionState.activate_buffer(workspace, buffers)
  end

  defp restore_return_target_buffer(workspace, _active_buffer), do: workspace

  @spec restore_prompt_focus(state(), boolean()) :: state()
  defp restore_prompt_focus(state, true),
    do: update_agent_ui(state, &PromptBuffer.set_input_focused(&1, true))

  defp restore_prompt_focus(state, false),
    do: update_agent_ui(state, &PromptBuffer.set_input_focused(&1, false))

  @spec mark_agent_view_inactive(state()) :: state()
  defp mark_agent_view_inactive(state) do
    update_agent_ui(state, fn ui ->
      {ui, _windows, _file_tree} = UIState.deactivate(ui)
      PromptBuffer.set_input_focused(ui, false)
    end)
  end

  @doc "Opens the explicit local/remote session picker."
  @spec start_session_picker(state()) :: state()
  def start_session_picker(state) do
    Minga.Telemetry.span([:minga, :agent, :start_session_picker], %{}, fn ->
      PickerUI.open(state, MingaEditor.UI.Picker.RemoteServerSource)
    end)
  end

  @doc "Connects to an existing remote session from the session picker."
  @spec connect_remote_session(state(), String.t(), String.t(), pid(), String.t()) :: state()
  def connect_remote_session(state, server_name, session_id, remote_pid, token) do
    AgentSession.connect_remote_session(state, server_name, session_id, remote_pid, token)
  end

  @doc """
  Submits the current input or continues the displayed stopped turn without sending the draft.

  While the active tab's start has failed, a prompt cannot be sent, so submit runs the failure's remedy instead and leaves the draft as it is. A known slash command such as `/login` or `/new` still runs, because it does not need the session. The draft is not sent after a retry; the user submits again once the session is ready.
  """
  @spec submit_prompt(state()) :: state()
  def submit_prompt(state) do
    case foreground_continue_target(state) do
      {session, target} ->
        TurnRequest.continue(state, session, target)

      nil ->
        if runs_start_remedy?(state.workspace.agent_ui),
          do: AgentSession.run_start_remedy(state),
          else: submit_draft(state)
    end
  end

  @doc "Continues the exact stopped turn shown by the frontend, never a replacement."
  @spec continue_displayed_turn(state(), {String.t(), String.t()}) :: state()
  def continue_displayed_turn(state, target) do
    case foreground_continue_target(state) do
      {session, ^target} ->
        TurnRequest.continue(state, session, target)

      _stale ->
        NoticeWorkflow.publish(state, "That stopped turn is no longer available.")
    end
  end

  @spec foreground_continue_target(state()) :: {pid(), {String.t(), String.t()}} | nil
  defp foreground_continue_target(state) do
    agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
    session = Runtime.active_session(state.shell_runtime)

    case agent.continue_target do
      {^session, _target} = bound when is_pid(session) -> bound
      _other -> nil
    end
  end

  @spec runs_start_remedy?(UIState.t()) :: boolean()
  defp runs_start_remedy?(%UIState{panel: panel} = ui) do
    UIState.start_remedy(ui) != nil and
      not SlashCommand.known_command?(PromptBuffer.prompt_text(panel))
  end

  @spec submit_draft(state()) :: state()
  defp submit_draft(state) do
    panel = state.workspace.agent_ui.panel

    submit_prompt(
      state,
      panel,
      pressed_text(state) |> String.trim() |> Kernel.==(""),
      Runtime.active_session(state.shell_runtime)
    )
  end

  # The text a send, queue or steer key takes: what no earlier press has already
  # taken while its queue is answered (`DraftWorkflow.pressed/1`).
  @spec pressed_text(state()) :: String.t()
  defp pressed_text(%{workspace: %{agent_ui: %UIState{panel: %Panel{prompt_buffer: pid}} = ui}})
       when is_pid(pid),
       do: ui |> DraftWorkflow.pressed() |> elem(0)

  defp pressed_text(state), do: PromptBuffer.prompt_text(state.workspace.agent_ui.panel)

  @spec submit_prompt(state(), Panel.t(), boolean(), pid() | nil) :: state()
  defp submit_prompt(state, _panel, true, _session), do: state

  defp submit_prompt(state, panel, false, nil) do
    if model_configured?(panel.model_name) do
      NoticeWorkflow.publish(state, "No agent session, try closing and reopening the panel")
    else
      NoticeWorkflow.publish(state, no_model_status())
    end
  end

  defp submit_prompt(state, _panel, false, _session) do
    text = pressed_text(state)

    if SlashCommand.indented_credential_command?(text) do
      reject_indented_credential_command(state)
    else
      submit_prompt_text(state, text, SlashCommand.slash_command?(text))
    end
  end

  @spec submit_prompt_text(state(), String.t(), boolean()) :: state()
  defp submit_prompt_text(state, text, true) do
    if SlashCommand.known_command?(text) do
      state = clear_submitted_slash_input(state, text)
      execute_slash_command(state, text)
    else
      report_unknown_slash_command(state, text)
    end
  end

  defp submit_prompt_text(state, text, false) do
    send_prompt_to_llm(state, text)
  end

  @spec reject_indented_credential_command(state()) :: state()
  defp reject_indented_credential_command(state) do
    state
    |> clear_submitted_slash_input_for_sensitivity(true)
    |> NoticeWorkflow.publish("Credential commands must start at the beginning of the prompt.")
  end

  @spec clear_submitted_slash_input(state(), String.t()) :: state()
  defp clear_submitted_slash_input(state, text) do
    clear_submitted_slash_input_for_sensitivity(state, SlashCommand.sensitive_command?(text))
  end

  @spec clear_submitted_slash_input_for_sensitivity(state(), boolean()) :: state()
  defp clear_submitted_slash_input_for_sensitivity(state, true) do
    update_agent_ui(
      state,
      &PromptBuffer.clear_input_without_history_and_scroll/1
    )
  end

  defp clear_submitted_slash_input_for_sensitivity(state, false) do
    update_agent_ui(state, &PromptBuffer.clear_input_and_scroll/1)
  end

  @spec execute_slash_command(state(), String.t()) :: state()
  defp execute_slash_command(state, text) do
    case SlashCommand.execute(state, text) do
      {:ok, state} -> state
      {:error, msg} -> NoticeWorkflow.publish(state, msg)
    end
  end

  @spec report_unknown_slash_command(state(), String.t()) :: state()
  defp report_unknown_slash_command(state, text) do
    message = SlashCommand.unknown_command_message(text)

    if Runtime.active_session(state.shell_runtime) do
      Session.add_system_message(
        Runtime.active_session(state.shell_runtime),
        message,
        :error
      )
    end

    NoticeWorkflow.publish(state, message)
  end

  @spec send_prompt_to_llm(state(), String.t()) :: state()
  defp send_prompt_to_llm(state, text) do
    if remote_session_disconnected?(state) do
      NoticeWorkflow.publish(
        state,
        "Session disconnected. Your prompt will be preserved."
      )
    else
      submit_connected_prompt(state, text, state.workspace.agent_ui.panel)
    end
  catch
    :exit, _ ->
      NoticeWorkflow.publish(
        state,
        "Agent session unavailable. Your prompt was preserved."
      )
  end

  @spec submit_connected_prompt(state(), String.t(), Panel.t()) :: state()
  defp submit_connected_prompt(state, text, panel) do
    case prompt_submit_status(state) do
      :ready ->
        state
        |> then(fn state ->
          TraditionalWorkflow.install_agent_panel(
            state,
            (&Panel.clear_provenance_jump/1).(state.workspace.agent_ui.panel)
          )
        end)
        |> resolve_and_deliver_prompt(text, panel.model_name)

      {:blocked, msg} ->
        NoticeWorkflow.publish(state, msg)
    end
  end

  @spec resolve_and_deliver_prompt(state(), String.t(), String.t()) :: state()
  defp resolve_and_deliver_prompt(state, text, model) do
    case resolve_prompt_for_session(state, text, model) do
      {:ok, resolved} ->
        deliver_composer(state, resolved, :steering)

      :read_files ->
        resolve_off_editor(state, :steering, text, :current)
    end
  end

  # Text that names files is read by a worker; the press waits in line meanwhile.
  # Without a saved draft to hold it on, a worker still reads the files and the
  # message goes only if its composer is unchanged (`deliver_read_mentions/3`).
  @spec resolve_off_editor(
          state(),
          :steering | :follow_up,
          String.t(),
          Session.queue_target() | :current
        ) ::
          state()
  defp resolve_off_editor(state, kind, text, expected) do
    case DraftWorkflow.resolve_then_deliver(state, delivery_kind(state, kind), text, expected) do
      {:held, held} ->
        held

      :not_held ->
        # A composer without a saved draft has no line to wait in; a worker still
        # reads the files, and the message goes when it answers.
        pressed = %{
          kind: kind,
          owner: DraftWorkflow.front_owner(state),
          session: Runtime.active_session(state.shell_runtime),
          raw: PromptBuffer.input_text(state.workspace.agent_ui)
        }

        :ok =
          DraftWorkflow.read_mentions_off_editor(
            state,
            text,
            state.workspace.agent_ui,
            &{:composer_mentions_read, pressed, &1}
          )

        state
    end
  end

  @typedoc "A press from a composer without a saved draft, whose mentioned files a worker is reading."
  @type read_press :: %{
          kind: :steering | :follow_up,
          owner: non_neg_integer() | nil,
          session: pid() | nil,
          raw: String.t()
        }

  @doc """
  Delivers a message from a composer without a saved draft once a worker has read the files it names. It goes only to the conversation it was pressed in, while that conversation is in front and its composer still holds exactly the pressed text; otherwise the text stays and one line says why.
  """
  @spec deliver_read_mentions(
          state(),
          read_press(),
          {:ok, String.t() | [ReqLLM.Message.ContentPart.t()]} | {:error, String.t()}
        ) :: state()
  def deliver_read_mentions(state, _pressed, {:error, message}),
    do:
      NoticeWorkflow.publish(
        state,
        MingaEditor.Agent.DraftWorkflow.not_sent(message)
      )

  def deliver_read_mentions(
        state,
        %{kind: kind, owner: owner, session: session, raw: raw},
        {:ok, resolved}
      ) do
    if DraftWorkflow.front_owner(state) == owner and
         Runtime.active_session(state.shell_runtime) == session and
         DraftWorkflow.only_pressed_text?(state, raw),
       do: deliver_composer(state, resolved, kind),
       else:
         NoticeWorkflow.publish(
           state,
           "Not sent: the message or its conversation changed while its files were read. Press send again."
         )
  end

  # Sends the resolved content to the LLM. The Session's answer arrives later
  # (`settle_turn_request/3`); the Editor never waits for it.
  @spec deliver_prompt(
          state(),
          String.t() | [ReqLLM.Message.ContentPart.t()],
          String.t() | :all
        ) :: state()
  defp deliver_prompt(state, resolved, raw),
    do:
      TurnRequest.deliver(
        state,
        Runtime.active_session(state.shell_runtime),
        :prompt,
        resolved,
        raw
      )

  @doc """
  Applies what a Session answered to a composer send, Stop, or Continue without blocking the Editor (`MingaEditor.Agent.TurnRequest`).

  A send that went removes its text from the composer it was pressed in, in front or not. A send that was refused, or whose Session exited before it answered, keeps the text and says why in one line.

  A stop that went says nothing when the modeline shows it. When it stopped a conversation the modeline does not speak for, one line names the task that was stopped.

  Continue keeps the draft. It says why if the stopped request is gone or cannot continue.
  """
  @spec settle_turn_request(state(), TurnRequest.t(), TurnRequest.answer()) :: state()
  def settle_turn_request(state, %TurnRequest{work: {:stop, _target}, session: session}, :ok),
    do: answer_unseen_stop(state, session)

  def settle_turn_request(state, %TurnRequest{work: {:stop, _target}}, {:error, :stale_turn}),
    do: NoticeWorkflow.publish(state, "That Agent turn is no longer active.")

  def settle_turn_request(state, %TurnRequest{work: {:stop, _target}}, _unanswered),
    do: NoticeWorkflow.publish(state, "Could not confirm the Agent stop request.")

  def settle_turn_request(state, %TurnRequest{work: {:continue, _target}}, :ok), do: state

  def settle_turn_request(state, %TurnRequest{work: {:continue, _target}}, {:error, :stale_turn}),
    do: NoticeWorkflow.publish(state, "That stopped turn is no longer available.")

  def settle_turn_request(state, %TurnRequest{work: {:continue, _target}}, {:error, reason}),
    do:
      NoticeWorkflow.publish(
        state,
        "Could not continue: #{MingaEditor.Agent.ErrorWords.describe(reason)}"
      )

  def settle_turn_request(state, %TurnRequest{work: {:continue, _target}}, :session_down),
    do: NoticeWorkflow.publish(state, "Agent session unavailable. Your prompt was preserved.")

  def settle_turn_request(
        state,
        %TurnRequest{work: {:send, send, _content, raw}} = request,
        answer
      ) do
    {outcome, notice} = composer_send_outcome(send, answer)

    state
    |> show_started_turn(request.session, answer)
    |> DraftWorkflow.send_answered(request.workspace, request.token, raw, outcome)
    |> publish_send_notice(notice)
  end

  # A send that started a turn names that turn's queue target in its answer. It is installed before
  # the press waiting behind the send runs, so that press queues into the new turn. The Session's
  # own event for the target can arrive after the answer; a press that ran in between would be sent
  # as a first message and refused.
  @spec show_started_turn(state(), pid(), TurnRequest.answer()) :: state()
  defp show_started_turn(state, session, {:sent, {_record, _request, _next} = target}),
    do: StatusEventWorkflow.queue_target_changed(state, session, target)

  defp show_started_turn(state, _session, _answer), do: state

  # The modeline says "Minga stopped" for the conversation it speaks for: the one in front, or,
  # with a file in front, the one shown last. A stop of any other conversation changes nothing
  # in view, so the echo area names the task that was stopped.
  @spec answer_unseen_stop(state(), pid()) :: state()
  defp answer_unseen_stop(state, session) do
    if WorkspaceStatus.spoken_session(state.shell_runtime.state) == session,
      do: state,
      else: NoticeWorkflow.publish(state, stopped_status(state, session))
  end

  @spec stopped_status(state(), pid()) :: String.t()
  defp stopped_status(state, session) do
    case stopped_name(state, session) do
      nil -> "Stopped"
      name -> "Stopped: #{name}"
    end
  end

  # The task's goal, or, for a task that was never given one here (a restored conversation),
  # the name its conversation has in the Spaces bar.
  @spec stopped_name(state(), pid()) :: String.t() | nil
  defp stopped_name(state, session) do
    case Tasks.fetch(state.agent_connection.tasks, session) do
      {:ok, %Tasks.Entry{title: title}} when is_binary(title) -> title
      _unnamed -> conversation_label(state, session)
    end
  end

  @spec conversation_label(state(), pid()) :: String.t() | nil
  defp conversation_label(state, session) do
    with %TabBar{} = tab_bar <- Runtime.traditional_tab_bar(state.shell_runtime),
         %{label: label} when is_binary(label) <-
           TabBar.find_workspace_by_session(tab_bar, session) do
      label
    else
      _none -> nil
    end
  end

  @spec publish_send_notice(state(), String.t() | nil) :: state()
  defp publish_send_notice(state, nil), do: state
  defp publish_send_notice(state, notice), do: NoticeWorkflow.publish(state, notice)

  @spec composer_send_outcome(Session.composer_send(), TurnRequest.answer()) ::
          {DraftWorkflow.send_answer(), String.t() | nil}
  defp composer_send_outcome(_send, :session_down),
    do: {:kept, "Agent session unavailable. Your prompt was preserved."}

  defp composer_send_outcome({:attached, _record, _shown}, {:ok, revision}),
    do: {{:sent_attached, revision}, nil}

  defp composer_send_outcome({:attached, _record, _shown}, {:accepted, revision, _reason}),
    do:
      {{:sent_attached, revision},
       "Prompt saved in the conversation, but the provider could not start it."}

  defp composer_send_outcome({:attached, _record, _shown}, {:error, reason}),
    do: {:kept, attached_submit_error(reason)}

  # A Session on this node names the turn it started; a Session on another node answers `:ok`.
  defp composer_send_outcome(_send, {:sent, _queue_target}), do: {{:sent, nil}, nil}
  defp composer_send_outcome(_send, :ok), do: {{:sent, nil}, nil}

  defp composer_send_outcome(_send, {:queued, :steering}),
    do: {{:sent, "⏳ Queued (steer). Ctrl-C to cancel."}, nil}

  defp composer_send_outcome(_send, {:queued, :follow_up}),
    do: {{:sent, "⏳ Queued (follow-up). Ctrl-C to cancel."}, nil}

  defp composer_send_outcome(_send, {:error, reason}), do: {:kept, prompt_refusal(reason)}

  defp composer_send_outcome(_send, other),
    do: {:kept, "Agent error: #{inspect(other)}"}

  @spec prompt_refusal(term()) :: String.t()
  defp prompt_refusal(:provider_not_ready), do: provider_starting_status()
  defp prompt_refusal(:credentials_pending), do: credentials_pending_status()
  defp prompt_refusal(:credentials_not_configured), do: credentials_missing_status()

  defp prompt_refusal(:queue_target_unavailable),
    do: "The Agent turn changed. Review the active turn and send again. The draft was kept."

  defp prompt_refusal(message) when is_binary(message), do: message
  defp prompt_refusal(reason), do: "Agent error: #{inspect(reason)}"

  @spec send_follow_up_to_llm(state(), String.t()) :: state()
  defp send_follow_up_to_llm(state, text) do
    if remote_session_disconnected?(state) do
      NoticeWorkflow.publish(
        state,
        "Session disconnected. Your prompt will be preserved."
      )
    else
      panel = state.workspace.agent_ui.panel

      case prompt_submit_status(state) do
        :ready -> resolve_and_deliver_follow_up(state, text, panel.model_name)
        {:blocked, msg} -> NoticeWorkflow.publish(state, msg)
      end
    end
  catch
    :exit, _ ->
      NoticeWorkflow.publish(
        state,
        "Agent session unavailable. Your prompt was preserved."
      )
  end

  @doc "Queues a displayed composer into exactly the rendered saved-session turn."
  @spec queue_displayed_prompt(state(), :steering | :follow_up, Session.queue_target()) :: state()
  def queue_displayed_prompt(state, kind, target) do
    panel = state.workspace.agent_ui.panel
    text = pressed_text(state)

    with false <- String.trim(text) == "",
         false <-
           SlashCommand.slash_command?(text) or SlashCommand.indented_credential_command?(text),
         :ready <- prompt_submit_status(state),
         {:ok, resolved} <- resolve_prompt_for_session(state, text, panel.model_name),
         {:saved, updated} <- DraftWorkflow.queue(state, kind, resolved, target) do
      updated
    else
      true ->
        NoticeWorkflow.publish(state, "Type a message to queue. Use Send for slash commands.")

      :ordinary ->
        NoticeWorkflow.publish(state, "That Agent turn is no longer active. Your draft was kept.")

      :read_files ->
        resolve_off_editor(state, kind, text, target)

      {:blocked, message} ->
        NoticeWorkflow.publish(state, message)
    end
  catch
    :exit, _ -> NoticeWorkflow.publish(state, "Agent session unavailable. Your draft was kept.")
  end

  @spec resolve_and_deliver_follow_up(state(), String.t(), String.t()) :: state()
  defp resolve_and_deliver_follow_up(state, text, model) do
    case resolve_prompt_for_session(state, text, model) do
      {:ok, resolved} ->
        deliver_composer(state, resolved, :follow_up)

      :read_files ->
        resolve_off_editor(state, :follow_up, text, :current)
    end
  end

  @spec deliver_composer(
          state(),
          String.t() | [ReqLLM.Message.ContentPart.t()],
          :steering | :follow_up
        ) ::
          state()
  defp deliver_composer(state, resolved, kind) do
    case DraftWorkflow.submission(state) do
      {:error, message} ->
        hold_or_refuse(state, delivery_kind(state, kind), resolved, message)

      submission ->
        # A press never overtakes one already waiting its turn.
        if DraftWorkflow.holding?(state),
          do:
            hold_or_refuse(
              state,
              delivery_kind(state, kind),
              resolved,
              "Wait for the earlier message to be queued."
            ),
          else: deliver_composer_input(state, kind, resolved, submission)
    end
  end

  # A press made while the draft's own bookkeeping is busy (loading, or answering
  # an earlier queue) waits for it (#4260); every other refusal is reported.
  @spec hold_or_refuse(
          state(),
          :send_now | :steering | :follow_up,
          String.t() | [ReqLLM.Message.ContentPart.t()],
          String.t()
        ) :: state()
  defp hold_or_refuse(state, kind, resolved, message) do
    case DraftWorkflow.hold_while_busy(state, kind, resolved) do
      {:held, held} -> held
      :not_busy -> NoticeWorkflow.publish(state, message)
    end
  end

  @spec delivery_kind(state(), :steering | :follow_up) :: :send_now | :steering | :follow_up
  defp delivery_kind(%{frontend: %{composer_send_now?: true}}, _kind), do: :send_now
  defp delivery_kind(_state, kind), do: kind

  @doc """
  Delivers a send that waited in line, with the content from its key press.

  It goes only while the composer still starts with the pressed text and no send or queue in flight has taken that text. Sending removes only that text, so typing after it and the text of a press waiting behind it stay. Otherwise nothing is sent, the composer keeps everything, the presses behind it stop waiting and one line says why. A send whose conversation is no longer in front is not sent either.
  """
  @spec deliver_held_send(
          state(),
          non_neg_integer(),
          {:send_now | :steering | :follow_up, String.t() | [ReqLLM.Message.ContentPart.t()],
           DraftSave.press()}
        ) :: state()
  def deliver_held_send(state, owner, {_kind, _content, {_source, raw, _marker}} = press) do
    cond do
      not DraftWorkflow.active_owner?(state, owner) ->
        state
        |> DraftWorkflow.drop_held(owner)
        |> NoticeWorkflow.publish(
          "A message was not sent because its conversation is no longer in front. Its text is still in that composer."
        )

      DraftWorkflow.pressed_text_in_front?(state, raw) ->
        deliver_held_in_front(state, owner, press, DraftWorkflow.submission(state))

      true ->
        state
        |> DraftWorkflow.drop_held(owner)
        |> NoticeWorkflow.publish(
          "Not sent: the message changed after you pressed send. Press send again."
        )
    end
  end

  @spec deliver_held_in_front(
          state(),
          non_neg_integer(),
          {:send_now | :steering | :follow_up, String.t() | [ReqLLM.Message.ContentPart.t()],
           DraftSave.press()},
          term()
        ) :: state()
  defp deliver_held_in_front(state, owner, _press, {:error, message}),
    do: state |> DraftWorkflow.drop_held(owner) |> NoticeWorkflow.publish(message)

  defp deliver_held_in_front(state, owner, {kind, content, press}, submission) do
    state
    |> deliver_held_input(kind, content, submission, press)
    |> DraftWorkflow.release_next(owner)
  end

  @spec deliver_held_input(
          state(),
          :send_now | :steering | :follow_up,
          String.t() | [ReqLLM.Message.ContentPart.t()],
          :ordinary
          | {:remote, DraftSave.target()}
          | {:attached, DraftSave.target(), [MingaAgent.DraftAttachment.identity()]},
          DraftSave.press()
        ) :: state()
  defp deliver_held_input(state, :send_now, content, submission, {_source, raw, _marker}),
    do: deliver_unqueued_composer(state, :send_now, content, submission, raw)

  defp deliver_held_input(state, kind, content, submission, press) do
    case DraftWorkflow.queue(state, kind, content, :current, press) do
      {:saved, updated} -> updated
      :ordinary -> deliver_unqueued_composer(state, kind, content, submission, elem(press, 1))
    end
  end

  @spec deliver_composer_input(
          state(),
          :steering | :follow_up,
          String.t() | [ReqLLM.Message.ContentPart.t()],
          :ordinary
          | {:remote, DraftSave.target()}
          | {:attached, DraftSave.target(), [MingaAgent.DraftAttachment.identity()]}
        ) :: state()
  defp deliver_composer_input(
         %{frontend: %{composer_send_now?: true}} = state,
         _kind,
         content,
         submission
       ),
       do: deliver_unqueued_composer(state, :send_now, content, submission, :all)

  defp deliver_composer_input(state, kind, content, submission) do
    case DraftWorkflow.queue(state, kind, content) do
      {:saved, updated} -> updated
      :ordinary -> deliver_unqueued_composer(state, kind, content, submission, :all)
    end
  end

  @spec deliver_unqueued_composer(
          state(),
          :send_now | :steering | :follow_up,
          String.t() | [ReqLLM.Message.ContentPart.t()],
          :ordinary
          | {:remote, DraftSave.target()}
          | {:attached, DraftSave.target(), [MingaAgent.DraftAttachment.identity()]},
          String.t() | :all
        ) :: state()
  defp deliver_unqueued_composer(
         %{
           workspace: %{
             agent_ui: %UIState{connection: %{target: %{session: session, session_id: record}}}
           }
         } = state,
         :send_now,
         content,
         :ordinary,
         raw
       )
       when node(session) == node(),
       do: TurnRequest.deliver(state, session, {:idle, record}, content, raw)

  defp deliver_unqueued_composer(state, :send_now, _content, :ordinary, _raw),
    do:
      NoticeWorkflow.publish(
        state,
        "This Agent daemon does not support exact Send. Use Enter or reconnect to an updated daemon."
      )

  defp deliver_unqueued_composer(
         %{
           workspace: %{
             agent_ui: %UIState{
               connection: %{persistent_drafts?: true, target: %{session: session}}
             }
           }
         } = state,
         :follow_up,
         _content,
         _submission,
         _raw
       )
       when node(session) == node() do
    NoticeWorkflow.publish(state, "That Agent turn is no longer active. Your draft was kept.")
  end

  defp deliver_unqueued_composer(
         %{
           workspace: %{
             agent_ui: %UIState{
               connection: %{
                 persistent_drafts?: true,
                 target: %{session: session, session_id: record}
               }
             }
           }
         } = state,
         _kind,
         content,
         :ordinary,
         raw
       )
       when node(session) == node() do
    if Runtime.active_session(state.shell_runtime) == session do
      TurnRequest.deliver(state, session, {:idle, record}, content, raw)
    else
      NoticeWorkflow.publish(state, "The Agent conversation changed. The draft was not sent.")
    end
  end

  defp deliver_unqueued_composer(state, _, content, {:remote, target}, _raw) do
    DraftWorkflow.submit_remote(state, target, [], content)
  end

  defp deliver_unqueued_composer(state, :steering, content, :ordinary, raw),
    do: deliver_prompt(state, content, raw)

  defp deliver_unqueued_composer(state, :follow_up, content, :ordinary, raw),
    do: deliver_follow_up(state, content, raw)

  defp deliver_unqueued_composer(state, _, content, {:attached, target, shown}, raw),
    do: deliver_attached_composer(state, target, shown, content, raw)

  @spec deliver_attached_composer(
          state(),
          DraftSave.target(),
          [MingaAgent.DraftAttachment.identity()],
          String.t() | [ReqLLM.Message.ContentPart.t()],
          String.t() | :all
        ) :: state()
  defp deliver_attached_composer(state, {session, _record} = target, shown, content, _raw)
       when node(session) != node(),
       do: DraftWorkflow.submit_remote(state, target, shown, content)

  defp deliver_attached_composer(state, {session, record}, shown, content, raw) do
    if Runtime.active_session(state.shell_runtime) == session do
      TurnRequest.deliver(state, session, {:attached, record, shown}, content, raw)
    else
      NoticeWorkflow.publish(state, "The Agent conversation changed. The draft was not sent.")
    end
  end

  @spec attached_submit_error(term()) :: String.t()
  defp attached_submit_error(:attachment_send_busy),
    do: "Wait for the active turn before sending attachments. The draft was kept."

  defp attached_submit_error(:draft_attachments_changed),
    do: "The saved attachments changed. Reopen the draft and review them before sending."

  defp attached_submit_error(:draft_attachments_too_large),
    do: "The attachments exceed this route's prompt limit. Remove context before sending."

  defp attached_submit_error(:attachment_route_unsupported),
    do: "The selected route cannot send these text attachments. Choose a text model."

  defp attached_submit_error(:provider_not_ready), do: provider_starting_status()
  defp attached_submit_error(:credentials_pending), do: credentials_pending_status()
  defp attached_submit_error(:credentials_not_configured), do: credentials_missing_status()

  defp attached_submit_error(_reason),
    do: "The attached prompt was not submitted. The draft was kept."

  @spec prompt_submit_status(state()) :: prompt_submit_status()
  defp prompt_submit_status(state) do
    case Runtime.active_session(state.shell_runtime) do
      session when is_pid(session) and node(session) != node() ->
        :ready

      session ->
        agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

        state.workspace.agent_ui
        |> prompt_readiness(session, agent.error)
        |> prompt_readiness_submit_status()
    end
  end

  @spec prompt_readiness(UIState.t(), pid() | nil, String.t() | nil) :: prompt_readiness()
  defp prompt_readiness(%UIState{panel: panel} = ui, session, error) do
    cond do
      model_configured?(panel.model_name) -> projected_prompt_readiness(ui, session, error)
      awaiting_session_model?(ui, session) -> :starting
      true -> :no_model
    end
  end

  # With no configured model the panel learns the model from the starting
  # session's first connection report (#3641); until then it is starting, not
  # unconfigured.
  @spec awaiting_session_model?(UIState.t(), pid() | nil) :: boolean()
  defp awaiting_session_model?(
         %UIState{connection: %ConnectionSnapshot{target: %{session: session}}},
         session
       ),
       do: false

  defp awaiting_session_model?(%UIState{chat_lifecycle: lifecycle}, _session),
    do: lifecycle == :starting

  @spec projected_prompt_readiness(UIState.t(), pid() | nil, String.t() | nil) ::
          prompt_readiness()
  defp projected_prompt_readiness(%UIState{chat_lifecycle: :unavailable}, _session, _error),
    do: :unavailable

  defp projected_prompt_readiness(
         %UIState{
           connection: %ConnectionSnapshot{target: %{session: session}} = connection,
           chat_lifecycle: lifecycle
         },
         session,
         error
       ),
       do: connection_prompt_readiness(connection, lifecycle, error)

  defp projected_prompt_readiness(%UIState{}, _session, _error), do: :starting

  @spec connection_prompt_readiness(
          ConnectionSnapshot.t(),
          UIState.chat_lifecycle(),
          String.t() | nil
        ) :: prompt_readiness()
  defp connection_prompt_readiness(%ConnectionSnapshot{provider_phase: :running}, _, _),
    do: :ready

  defp connection_prompt_readiness(%ConnectionSnapshot{credential_readiness: :checking}, _, _),
    do: :credentials_checking

  defp connection_prompt_readiness(
         %ConnectionSnapshot{credential_readiness: :unconfigured},
         _,
         _
       ),
       do: :credentials_missing

  defp connection_prompt_readiness(%ConnectionSnapshot{}, {:failed, failure}, _),
    do: {:start_failed, failure}

  defp connection_prompt_readiness(%ConnectionSnapshot{}, _, error)
       when is_binary(error) and error != "", do: {:startup_failed, error}

  defp connection_prompt_readiness(%ConnectionSnapshot{}, _, _), do: :starting

  @spec model_configured?(String.t()) :: boolean()
  defp model_configured?(model) when model in ["", "unknown"], do: false
  defp model_configured?(model), do: model != AgentConfig.unconfigured_model()

  @spec prompt_readiness_submit_status(prompt_readiness()) :: prompt_submit_status()
  defp prompt_readiness_submit_status(:ready), do: :ready
  defp prompt_readiness_submit_status(:no_model), do: {:blocked, no_model_status()}

  defp prompt_readiness_submit_status(:credentials_missing),
    do: {:blocked, credentials_missing_status()}

  defp prompt_readiness_submit_status(:credentials_checking),
    do: {:blocked, credentials_pending_status()}

  defp prompt_readiness_submit_status(:starting), do: {:blocked, provider_starting_status()}

  defp prompt_readiness_submit_status(:unavailable) do
    {:blocked, "Agent session unavailable. Your prompt was preserved."}
  end

  defp prompt_readiness_submit_status({:startup_failed, error}) do
    {:blocked, provider_startup_failed_status(error)}
  end

  defp prompt_readiness_submit_status({:start_failed, failure}) do
    {:blocked, "#{failure.message} Your prompt was preserved."}
  end

  @spec no_model_status() :: String.t()
  defp no_model_status do
    "No model configured. Your prompt was preserved. Run /auth, /login, or pick a configured model."
  end

  @spec credentials_missing_status() :: String.t()
  defp credentials_missing_status do
    "No provider credentials are configured for this model. Your prompt was preserved. Run /auth or /login to set one up."
  end

  @spec credentials_pending_status() :: String.t()
  defp credentials_pending_status,
    do: "Checking hosted provider credentials. Your prompt was preserved."

  @spec provider_starting_status() :: String.t()
  defp provider_starting_status do
    "Agent provider still starting. Your prompt was preserved."
  end

  @spec provider_startup_failed_status(String.t()) :: String.t()
  defp provider_startup_failed_status(error) do
    message = provider_startup_failed_message(error)
    "#{message}. Your prompt was preserved."
  end

  @spec provider_startup_failed_message(String.t()) :: String.t()
  defp provider_startup_failed_message("Failed to start agent: " <> _rest = message),
    do: String.trim_trailing(message, ".")

  defp provider_startup_failed_message(error),
    do: "Failed to start agent: #{String.trim_trailing(error, ".")}"

  # Plain text needs nothing resolved. Text that names files must be read, which
  # can block, so a worker does it (`:read_files`) instead of the Editor (#4260).
  @spec resolve_prompt_for_session(state(), String.t(), String.t()) ::
          {:ok, String.t()} | :read_files
  defp resolve_prompt_for_session(state, text, _model) do
    cond do
      remote_session?(state) -> {:ok, text}
      FileMention.extract_mentions(text) == [] -> {:ok, text}
      true -> :read_files
    end
  end

  @spec remote_session?(state()) :: boolean()
  defp remote_session?(state) do
    case Runtime.active_session(state.shell_runtime) do
      pid when is_pid(pid) -> node(pid) != node()
      _ -> false
    end
  end

  @spec remote_session_disconnected?(state()) :: boolean()
  defp remote_session_disconnected?(state) do
    case Runtime.active_session(state.shell_runtime) do
      pid when is_pid(pid) and node(pid) != node() -> remote_node_disconnected?(node(pid))
      _ -> false
    end
  end

  @spec remote_node_disconnected?(node()) :: boolean()
  defp remote_node_disconnected?(remote_node) do
    case Minga.Distribution.ConnectionManager.server_name_for_node(remote_node) do
      {:ok, server_name} -> not Minga.Distribution.ConnectionManager.connected?(server_name)
      {:error, :not_found} -> true
    end
  end

  @spec deliver_follow_up(
          state(),
          String.t() | [ReqLLM.Message.ContentPart.t()],
          String.t() | :all
        ) :: state()
  defp deliver_follow_up(state, resolved, raw),
    do:
      TurnRequest.deliver(
        state,
        Runtime.active_session(state.shell_runtime),
        :follow_up,
        resolved,
        raw
      )

  @spec project_root() :: String.t() | nil
  defp project_root, do: Minga.Project.resolve_root()

  @doc "Clears the chat display without affecting conversation history."
  @spec clear_chat_display(state()) :: state()
  def clear_chat_display(state) do
    msg_count = TranscriptProjection.source_count(state.workspace.agent_ui.panel.transcript)

    state = update_agent_ui(state, &UIState.clear_display(&1, msg_count))

    if Runtime.active_session(state.shell_runtime) do
      Session.add_system_message(
        Runtime.active_session(state.shell_runtime),
        "Display cleared"
      )
    end

    state
  end

  @doc """
  Stops the turn Minga is working on (`SPC a s`, `⌘.`).

  The queue is kept: queued messages stay in `*minga-queue*` and are sent after the next turn. The composer keeps its draft, and the Session reports the status `:stopped`, which the modeline speaks as "Minga stopped".
  """
  @spec abort_agent(state()) :: state()
  def abort_agent(state) do
    case turn_to_stop(state) do
      {session, target} -> TurnRequest.stop(state, session, target)
      :several -> NoticeWorkflow.publish(state, several_working_status())
      nil -> state
    end
  end

  # Stop works from any buffer, so it does not need a conversation in front. It stops one
  # turn: the turn of the conversation in front; with none in front, the turn of the
  # conversation shown last, or the only turn there is. Every followed session reports its
  # own turn (`Tasks.stoppable/1`), so a turn in a background workspace is known too.
  @spec turn_to_stop(state()) :: {pid(), {String.t(), String.t()}} | :several | nil
  defp turn_to_stop(state) do
    stoppable = Tasks.stoppable(state.agent_connection.tasks)
    agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

    case Runtime.active_session(state.shell_runtime) do
      session when is_pid(session) -> List.keyfind(stoppable, session, 0) || agent.stop_target
      nil -> background_turn_to_stop(stoppable, AgentState.session(agent))
    end
  end

  # `shown_last` is the conversation the modeline of a file speaks for (`MingaEditor.Agent.WorkspaceStatus`).
  @spec background_turn_to_stop([{pid(), {String.t(), String.t()}}], pid() | nil) ::
          {pid(), {String.t(), String.t()}} | :several | nil
  defp background_turn_to_stop([], _shown_last), do: nil
  defp background_turn_to_stop([only], _shown_last), do: only
  defp background_turn_to_stop(_stoppable, nil), do: :several

  defp background_turn_to_stop(stoppable, shown_last),
    do: List.keyfind(stoppable, shown_last, 0) || :several

  @spec several_working_status() :: String.t()
  defp several_working_status,
    do: "Several conversations are working. Bring the one to stop to the front, then stop it."

  @doc "Stops the turn shown on an attached Agent surface, never its replacement."
  @spec stop_displayed_turn(state(), {String.t(), String.t()}) :: state()
  def stop_displayed_turn(state, target) do
    agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

    with {session, ^target} <- agent.stop_target,
         ^session <- Runtime.active_session(state.shell_runtime) do
      TurnRequest.stop(state, session, target)
    else
      _ -> NoticeWorkflow.publish(state, "That Agent turn is no longer active.")
    end
  end

  @doc "Retries the current agent provider after a startup or crash error."
  @spec restart_agent_provider(state()) :: state()
  def restart_agent_provider(state) do
    case Runtime.active_session(state.shell_runtime) do
      nil ->
        NoticeWorkflow.publish(state, "No agent session to restart")

      session ->
        case Session.restart_provider(session) do
          :ok ->
            NoticeWorkflow.publish(
              state,
              "Agent provider restarted"
            )

          {:error, reason} ->
            NoticeWorkflow.publish(
              state,
              "Agent restart failed: #{inspect(reason)}"
            )
        end
    end
  catch
    :exit, _ ->
      NoticeWorkflow.publish(state, "Agent restart failed")
  end

  @doc """
  Pulls all queued messages back into the prompt input without aborting the agent.

  Useful when you want to re-read or edit your queued messages. Does not stop streaming.
  """
  @spec dequeue_to_editor(state()) :: state()
  def dequeue_to_editor(state) do
    case Runtime.active_session(state.shell_runtime) do
      nil ->
        state

      session ->
        recall_queued_input(state, session, &do_dequeue_to_editor/2)
    end
  end

  @spec recall_queued_input(
          state(),
          pid(),
          (state(), [String.t() | [ReqLLM.Message.ContentPart.t()]] -> state())
        ) :: state()
  defp recall_queued_input(state, session, restore) do
    case DraftWorkflow.recall(state, session) do
      {:saved, updated} -> updated
      :volatile -> restore_volatile_queue(state, safe_recall_queues(session), restore)
    end
  end

  @spec restore_volatile_queue(
          state(),
          {[String.t() | [ReqLLM.Message.ContentPart.t()]],
           [String.t() | [ReqLLM.Message.ContentPart.t()]]}
          | {:error, :saved_draft_required},
          (state(), [String.t() | [ReqLLM.Message.ContentPart.t()]] -> state())
        ) :: state()
  defp restore_volatile_queue(state, {:error, :saved_draft_required}, _restore),
    do: queue_recall_unavailable(state)

  defp restore_volatile_queue(state, {steering, follow_up}, restore),
    do: restore.(state, steering ++ follow_up)

  @doc "Queues the current input as a follow-up; submits normally when agent is idle."
  @spec scope_queue_follow_up(state()) :: state()
  def scope_queue_follow_up(state) do
    text = pressed_text(state)

    cond do
      String.trim(text) == "" ->
        state

      Runtime.active_session(state.shell_runtime) == nil ->
        NoticeWorkflow.publish(
          state,
          "No agent session, try closing and reopening the panel"
        )

      MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state).runtime.status in [
        :thinking,
        :tool_executing
      ] ->
        case {SlashCommand.indented_credential_command?(text), SlashCommand.slash_command?(text)} do
          {true, _} ->
            reject_indented_credential_command(state)

          {false, true} ->
            state = clear_submitted_slash_input(state, text)
            execute_slash_command(state, text)

          {false, false} ->
            send_follow_up_to_llm(state, text)
        end

      true ->
        # Agent is idle: queueing sends the message now.
        submit_prompt(state)
    end
  end

  @doc "Dequeues all pending messages back into the prompt input without aborting."
  @spec scope_dequeue(state()) :: state()
  def scope_dequeue(state), do: dequeue_to_editor(state)

  @doc """
  Context-sensitive Ctrl-C handler.

  Always leaves Insert mode, as Escape does (vim convention). While this conversation has a turn to stop it also stops the turn, as `SPC a s` does, and keeps the queue: that includes a turn that waits for an approval, a turn in plan mode and a turn that reported an error and is still running. With no turn to stop, after a provider error it restarts the provider.
  """
  @spec scope_ctrl_c(state()) :: state()
  def scope_ctrl_c(state) do
    state
    |> interrupt_for_ctrl_c(MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state))
    |> input_to_normal()
  end

  # Stop acts on the stop target, so the composer's `⌃C stop` hint and this
  # command agree on when there is something to stop.
  @spec interrupt_for_ctrl_c(state(), MingaEditor.State.Agent.t()) :: state()
  defp interrupt_for_ctrl_c(state, %{stop_target: {_session, _target}}), do: abort_agent(state)

  defp interrupt_for_ctrl_c(state, %{runtime: %{status: :error}}),
    do: restart_agent_provider(state)

  defp interrupt_for_ctrl_c(state, _agent), do: state

  @doc "Starts an agent session if one isn't already running. No-op otherwise."
  @spec ensure_agent_session(state()) :: state()
  def ensure_agent_session(state) do
    if Runtime.active_session(state.shell_runtime) == nil do
      AgentSession.start_agent_session(state)
    else
      state
    end
  end

  @doc """
  Creates a new active agent workspace with a fresh session.

  The new workspace starts with no file membership. The agent tab is the zoom surface for the workspace, not a file tab copied from the source workspace.
  """
  @spec new_agent_session(state()) :: state()
  def new_agent_session(state) do
    CatalogStartup.continue(state, :new)
  end

  @spec new_ready_session(state()) :: state()
  defp new_ready_session(state) do
    thinking_level = state.workspace.agent_ui.panel.thinking_level
    from_home = home_return_target(state)

    state
    |> measured_agent_tab_switch()
    |> reset_agent_state_for_new_session(thinking_level)
    |> remember_home(from_home)
    |> AgentSession.start_agent_session(recover_interrupted_work?: false)
    # The person took the step the read-only card offers, by key or by click.
    |> MingaEditor.Handlers.Notifications.dismiss_conversation_read_only()
    |> scope_focus_input()
  end

  # A task started from the project home (no tab active) returns there when it is left, even with file tabs behind it.
  @spec home_return_target(state()) :: UIState.View.return_target() | nil
  defp home_return_target(state) do
    case active_tab_id(state) do
      nil -> build_return_target(state)
      _tab -> nil
    end
  end

  @spec remember_home(state(), UIState.View.return_target() | nil) :: state()
  defp remember_home(state, nil), do: state

  defp remember_home(state, return_target),
    do: update_agent_ui(state, &UIState.set_return_target(&1, return_target))

  @spec reset_agent_state_for_new_session(state(), String.t() | nil) :: state()
  defp reset_agent_state_for_new_session(state, thinking_level) do
    state = TraditionalWorkflow.install_agent_state(state, %AgentState{})

    agent_ui =
      UIState.new()
      |> UIState.set_thinking_level(thinking_level)
      |> UIState.toggle()
      |> UIState.activate(state.workspace.windows, state.workspace.file_tree)
      |> retain_arrived_composer(state.workspace.agent_ui.panel.prompt_buffer)

    TraditionalWorkflow.install_agent_ui(state, agent_ui)
  end

  @spec retain_arrived_composer(UIState.t(), pid() | nil) :: UIState.t()
  defp retain_arrived_composer(ui, pid) when is_pid(pid),
    do: UIState.attach_prompt_buffer(ui, pid)

  defp retain_arrived_composer(ui, nil), do: ui

  @spec measured_tab_switch(state(), Tab.id()) :: state()
  defp measured_tab_switch(state, tab_id) do
    Minga.Telemetry.span([:minga, :agent, :tab_switch], %{}, fn ->
      TabWorkflow.switch(state, tab_id)
    end)
  end

  @spec measured_agent_tab_switch(state()) :: state()
  defp measured_agent_tab_switch(state) do
    Minga.Telemetry.span([:minga, :agent, :tab_switch], %{}, fn ->
      create_active_agent_tab(state)
    end)
  end

  @spec create_active_agent_tab(state()) :: state()
  defp create_active_agent_tab(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state) do
    {tb, tab} =
      TabWorkflow.insert_agent(
        tb,
        "Agent",
        state.frontend.terminal_viewport,
        state.workspace.file_tree.project_root
      )

    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        tb
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
    |> TabWorkflow.switch(tab.id)
  end

  defp create_active_agent_tab(state), do: state

  @doc "Stops the current agent session process."
  @spec stop_current_session(state()) :: state()
  def stop_current_session(state), do: AgentSession.stop_current_session(state)

  @doc "Clears all saved agent sessions from disk."
  @spec clear_session_history(state()) :: state()
  def clear_session_history(state) do
    count = Enum.count(SessionStore.list())
    SessionStore.clear_all()

    msg =
      case count do
        0 -> "No saved agent sessions"
        1 -> "Cleared 1 agent session"
        n -> "Cleared #{n} agent sessions"
      end

    NoticeWorkflow.publish(state, msg)
  end

  @doc "Scrolls the chat panel up by half the panel height."
  @spec scroll_chat_up(state()) :: state()
  def scroll_chat_up(state) do
    amount = div(panel_height(state), 2)
    state = update_agent_ui(state, &UIState.scroll_up(&1, amount))
    scroll_agent_chat_window(state, -amount)
  end

  @doc "Scrolls the chat panel down by half the panel height."
  @spec scroll_chat_down(state()) :: state()
  def scroll_chat_down(state) do
    amount = div(panel_height(state), 2)
    state = update_agent_ui(state, &UIState.scroll_down(&1, amount))
    scroll_agent_chat_window(state, amount)
  end

  @doc "Handles a character input in the agent prompt."
  @spec input_char(state(), String.t()) :: state()
  def input_char(state, char) do
    update_agent_ui(state, &PromptBuffer.insert_char(&1, char))
  end

  @doc "Inserts pasted text into the agent prompt. Collapses multi-line pastes into a compact indicator."
  @spec input_paste(state(), String.t()) :: state()
  def input_paste(state, text) do
    update_agent_ui(state, &PromptBuffer.insert_paste(&1, text))
  end

  @doc "Toggles expand/collapse on the paste block at the cursor."
  @spec toggle_paste_expand(state()) :: state()
  def toggle_paste_expand(state) do
    update_agent_ui(state, &PromptBuffer.toggle_paste_expand/1)
  end

  @doc "Deletes the last character from the agent prompt."
  @spec input_backspace(state()) :: state()
  def input_backspace(state) do
    update_agent_ui(state, &PromptBuffer.delete_char/1)
  end

  @doc "Cycles the thinking level (off → low → medium → high)."
  @spec cycle_thinking_level(state()) :: state()
  def cycle_thinking_level(state) do
    case Runtime.active_session(state.shell_runtime) do
      nil ->
        NoticeWorkflow.publish(state, "No agent session")

      session ->
        case Session.cycle_thinking_level(session) do
          {:ok, %{"level" => level}} when is_binary(level) ->
            apply_thinking_level(state, session, level)

          {:ok, nil} ->
            NoticeWorkflow.publish(
              state,
              "Model does not support thinking levels"
            )

          {:error, reason} ->
            NoticeWorkflow.publish(
              state,
              "Error: #{inspect(reason)}"
            )
        end
    end
  end

  @doc "Sets the thinking level to off."
  @spec set_thinking_off(state()) :: state()
  def set_thinking_off(state), do: set_thinking_level(state, "off")

  @doc "Sets the thinking level to low."
  @spec set_thinking_low(state()) :: state()
  def set_thinking_low(state), do: set_thinking_level(state, "low")

  @doc "Sets the thinking level to medium."
  @spec set_thinking_medium(state()) :: state()
  def set_thinking_medium(state), do: set_thinking_level(state, "medium")

  @doc "Sets the thinking level to high."
  @spec set_thinking_high(state()) :: state()
  def set_thinking_high(state), do: set_thinking_level(state, "high")

  @doc "Sets the thinking level to the given provider-supported value."
  @spec set_thinking_level(state(), String.t()) :: state()
  def set_thinking_level(state, level) when is_binary(level) do
    case Runtime.active_session(state.shell_runtime) do
      nil ->
        NoticeWorkflow.publish(state, "No agent session")

      session ->
        case Session.set_thinking_level(session, level) do
          :ok ->
            apply_thinking_level(state, session, level)

          {:error, reason} ->
            NoticeWorkflow.publish(
              state,
              "Error: #{inspect(reason)}"
            )
        end
    end
  end

  @doc "Opens a picker for selecting the agent thinking level."
  @spec pick_thinking_level(state()) :: state()
  def pick_thinking_level(state) do
    if Runtime.active_session(state.shell_runtime) == nil do
      NoticeWorkflow.publish(state, "No agent session")
    else
      current_level = state.workspace.agent_ui.panel.thinking_level

      PickerUI.open(state, MingaEditor.UI.Picker.ThinkingLevelSource, %{
        current_level: current_level
      })
    end
  end

  @spec apply_thinking_level(state(), pid(), String.t()) :: state()
  defp apply_thinking_level(state, session, level) do
    state = update_agent_ui(state, &UIState.set_thinking_level(&1, level))
    Session.add_system_message(session, "Thinking: #{level}")
    NoticeWorkflow.publish(state, "Thinking: #{level}")
  end

  @spec apply_model_and_provider(state(), String.t(), String.t()) :: state()
  defp apply_model_and_provider(state, model, provider) do
    state
    |> update_agent_ui(&UIState.set_model_name(&1, model))
    |> update_agent_ui(&UIState.set_provider_name(&1, provider))
  end

  @doc "Sets an exact agent model route without resetting conversation context."
  @spec set_model(state(), String.t() | ModelSelection.t()) :: state()
  def set_model(state, model_or_selection) do
    MingaEditor.Agent.ConnectionAction.schedule_current(state, {:model, model_or_selection})
  end

  @spec apply_restored_model_selection(state(), ModelSelection.t() | nil) :: state()
  defp apply_restored_model_selection(state, %ModelSelection{} = selection),
    do: apply_model_selection_to_ui(state, selection)

  defp apply_restored_model_selection(state, nil), do: state

  @spec apply_model_selection_to_ui(state(), ModelSelection.t()) :: state()
  defp apply_model_selection_to_ui(state, %ModelSelection{} = selection) do
    state
    |> apply_model_and_provider(selection.route.display_name, selection.route.model_provider)
    |> update_agent_ui(&UIState.set_thinking_level(&1, selection.policy.reasoning.effort))
  end

  # ── Scope commands (keymap scope dispatch) ──────────────────────────────────
  #
  # These commands are bound in Keymap.Scope.Agent and dispatched through the
  # scope resolution system. Focus-aware commands check state.workspace.agent_ui.focus to
  # route to the correct panel (chat vs file viewer).

  # ── Fold / Collapse ────────────────────────────────────────────────────────

  @doc "Toggles all collapsible agent blocks."
  @spec scope_toggle_all_collapse(state()) :: state()
  def scope_toggle_all_collapse(state) do
    if session = Runtime.active_session(state.shell_runtime) do
      Session.toggle_all_tool_collapses(session)
    end

    state
  end

  # ── Bracket navigation ────────────────────────────────────────────────────

  @doc "Jumps to next code block or diff hunk."
  @spec scope_next_code_block(state()) :: state()
  def scope_next_code_block(state) do
    update_preview(state, &Preview.navigate_hunk(&1, :next))
  end

  @doc "Jumps to previous code block or diff hunk."
  @spec scope_prev_code_block(state()) :: state()
  def scope_prev_code_block(state) do
    update_preview(state, &Preview.navigate_hunk(&1, :previous))
  end

  # ── Copy ───────────────────────────────────────────────────────────────────

  @doc "Copies the code block at the cursor to the clipboard."
  @spec scope_copy_code_block(state()) :: state()
  def scope_copy_code_block(state) do
    case scroll_context(state) do
      nil ->
        state

      {_id, msg, offset, line_type} ->
        text = Message.text(msg)

        if line_type == :code do
          blocks = Markdown.extract_code_blocks(text)
          content = code_block_for_scroll(msg, offset, blocks)
          copy_to_clipboard(state, content, "code block")
        else
          copy_to_clipboard(state, text, "message")
        end
    end
  end

  @doc "Copies the full message at the cursor to the clipboard."
  @spec scope_copy_message(state()) :: state()
  def scope_copy_message(state) do
    case scroll_context(state) do
      nil -> state
      {_id, msg, _offset, _type} -> copy_to_clipboard(state, Message.text(msg), "message")
    end
  end

  # ── Open code block ────────────────────────────────────────────────────────

  @doc "Opens the code block at the cursor in an editor buffer."
  @spec scope_open_code_block(state()) :: state()
  def scope_open_code_block(state) do
    case scroll_context(state) do
      nil ->
        state

      {_id, msg, offset, :code} ->
        text = Message.text(msg)
        blocks = Markdown.extract_code_blocks(text)
        block = Enum.at(blocks, code_block_index_for_scroll(msg, offset, blocks))

        if block,
          do: AgentSession.open_code_block(state, block.language, block.content),
          else: state

      {_id, _msg, _offset, _other_type} ->
        state
    end
  end

  # ── Apply code block ───────────────────────────────────────────────────────

  @doc "Applies the code block at the cursor to the inferred target file with diff preview."
  @spec scope_apply_code_block(state()) :: state()
  def scope_apply_code_block(state) do
    case scroll_context(state) do
      nil ->
        state

      {_id, msg, offset, :code} ->
        text = Message.text(msg)
        blocks = Markdown.extract_code_blocks(text)
        block_index = code_block_index_for_scroll(msg, offset, blocks)
        block = Enum.at(blocks, block_index)

        if block do
          apply_code_block(state, text, block, block_index)
        else
          state
        end

      {_id, _msg, _offset, _other_type} ->
        state
    end
  end

  @spec apply_code_block(state(), String.t(), Markdown.code_block(), non_neg_integer()) :: state()
  defp apply_code_block(state, message_text, block, block_index) do
    case Markdown.infer_target_path(message_text, block_index) do
      nil ->
        NoticeWorkflow.publish(
          state,
          "No file path found near code block. Copy with `yy` instead."
        )

      path ->
        full_path = resolve_apply_path(path)
        apply_code_block_to_path(state, full_path, block.content, path)
    end
  end

  @spec resolve_apply_path(String.t()) :: String.t()
  defp resolve_apply_path(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(project_root(), path)
    end
  end

  @spec apply_code_block_to_path(state(), String.t(), String.t(), String.t()) :: state()
  defp apply_code_block_to_path(state, full_path, content, display_path) do
    case File.read(full_path) do
      {:ok, before_content} ->
        apply_code_block_diff(state, full_path, before_content, content, display_path)

      {:error, :enoent} ->
        create_file_from_code_block(state, full_path, content, display_path)

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Cannot read #{display_path}: #{inspect(reason)}"
        )
    end
  end

  @spec apply_code_block_diff(state(), String.t(), String.t(), String.t(), String.t()) :: state()
  defp apply_code_block_diff(state, path, before_content, content, display_path) do
    case DiffReview.new(path, before_content, content) do
      nil ->
        NoticeWorkflow.publish(
          state,
          "No changes detected for #{display_path}"
        )

      review ->
        state = update_preview(state, &Preview.set_diff(&1, DiffReview.as_proposal(review)))
        state = update_agent_ui(state, &UIState.set_focus(&1, :file_viewer))
        log_system_message(state, "Applying code block to #{display_path}")

        NoticeWorkflow.publish(
          state,
          "Diff preview for #{display_path}. Accept/reject hunks."
        )
    end
  end

  @spec create_file_from_code_block(state(), String.t(), String.t(), String.t()) :: state()
  defp create_file_from_code_block(state, full_path, content, display_path) do
    with :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.write(full_path, content) do
      log_system_message(state, "Created #{display_path}")
      NoticeWorkflow.publish(state, "Created #{display_path}")
    else
      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Failed to create #{display_path}: #{inspect(reason)}"
        )
    end
  end

  @spec log_system_message(state(), String.t()) :: :ok
  defp log_system_message(state, text) do
    case Runtime.active_session(state.shell_runtime) do
      pid when is_pid(pid) -> Session.add_system_message(pid, text)
      _ -> :ok
    end
  end

  # ── Pin message ────────────────────────────────────────────────────────────

  @doc "Toggles the pinned state of the message at the cursor."
  @spec scope_pin_message(state()) :: state()
  def scope_pin_message(state) do
    with session when is_pid(session) <-
           Runtime.active_session(state.shell_runtime),
         {id, msg, _offset, _line_type} <- scroll_context(state),
         false <- synthetic_display_message?(msg) do
      Session.toggle_pin(session, id)
    end

    state
  catch
    :exit, _ -> state
  end

  @spec synthetic_display_message?(term()) :: boolean()
  defp synthetic_display_message?({:system, "── pinned ──", :info}), do: true
  defp synthetic_display_message?({:system, "── " <> _rest, :info}), do: true
  defp synthetic_display_message?(_msg), do: false

  # ── Input focus ────────────────────────────────────────────────────────────

  @doc "Focuses the input field and transitions to insert mode."
  @spec scope_focus_input(state()) :: state()
  def scope_focus_input(state) do
    state =
      state
      |> Commands.FileTree.leave_focus()
      |> update_agent_ui(&PromptBuffer.set_input_focused(&1, true))

    %{state | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :insert)}
  end

  @doc "Unfocuses the input field and transitions to normal mode."
  @spec scope_unfocus_input(state()) :: state()
  def scope_unfocus_input(state) do
    state = update_agent_ui(state, &PromptBuffer.set_input_focused(&1, false))
    %{state | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :normal)}
  end

  @doc "Unfocuses the input field and closes the agent split pane."
  @spec scope_unfocus_and_quit(state()) :: state()
  def scope_unfocus_and_quit(state) do
    state = update_agent_ui(state, &PromptBuffer.set_input_focused(&1, false))
    toggle_agent_split(state)
  end

  # ── Input vim mode commands ──────────────────────────────────────────────
  #
  # Vim editing (motions, operators, visual mode, counts, text objects) is
  # handled by the standard Mode FSM via dispatch_prompt_via_mode_fsm.
  # Only mode transitions that originate from scope trie bindings live here.

  @doc "Switches the input from insert to normal mode. Delegates to Mode FSM via Escape."
  @spec input_to_normal(state()) :: state()
  def input_to_normal(state) do
    # Route Escape through the prompt's Mode FSM which handles the
    # insert → normal transition, cursor clamping, etc.
    AgentPanel.dispatch_prompt_via_mode_fsm(state, 27, 0)
  end

  # ── Panel management ───────────────────────────────────────────────────────

  @doc "Grows the chat panel width."
  @spec scope_grow_panel(state()) :: state()
  def scope_grow_panel(state), do: update_agent_ui(state, &UIState.grow_chat/1)

  @doc "Shrinks the chat panel width."
  @spec scope_shrink_panel(state()) :: state()
  def scope_shrink_panel(state), do: update_agent_ui(state, &UIState.shrink_chat/1)

  @doc "Resets the panel split to the default ratio."
  @spec scope_reset_panel(state()) :: state()
  def scope_reset_panel(state), do: update_agent_ui(state, &UIState.reset_split/1)

  @doc "Resumes the retained chat draft without changing its text, selection or editing mode."
  @spec return_to_chat(state()) :: state()
  def return_to_chat(state) do
    ui =
      state.workspace.agent_ui
      |> UIState.set_input_focused(true)
      |> UIState.clear_prefix()

    state
    |> Commands.FileTree.leave_focus()
    |> TraditionalWorkflow.install_agent_ui(ui)
  end

  @doc "Switches focus between chat and file viewer panels."
  @spec scope_switch_focus(state()) :: state()
  def scope_switch_focus(state) do
    case UIState.switch_focus(state.workspace.agent_ui) do
      {:ok, ui} ->
        TraditionalWorkflow.install_agent_ui(state, ui)

      {:error, :no_review} ->
        NoticeWorkflow.publish(state, "No review selected. Choose Review for a changed file.")
    end
  end

  # ── Search ─────────────────────────────────────────────────────────────────

  @spec scope_start_search(state()) :: state()
  def scope_start_search(state), do: AgentSubStates.start_search(state)

  @spec scope_next_search_match(state()) :: state()
  def scope_next_search_match(state), do: AgentSubStates.next_match(state)

  @spec scope_prev_search_match(state()) :: state()
  def scope_prev_search_match(state), do: AgentSubStates.prev_match(state)

  # ── Session ────────────────────────────────────────────────────────────────

  @doc "Opens the session switcher picker."
  @spec scope_session_switcher(state()) :: state()
  def scope_session_switcher(state) do
    MingaEditor.UI.Picker.AgentSessionSource.open(state)
  end

  # ── Help ───────────────────────────────────────────────────────────────────

  @doc "Toggles the help overlay."
  @spec scope_toggle_help(state()) :: state()
  def scope_toggle_help(state), do: update_agent_ui(state, &UIState.toggle_help/1)

  @doc "Closes Agent Help without changing the covered draft or Review."
  @spec scope_dismiss_help(state()) :: state()
  def scope_dismiss_help(state), do: update_agent_ui(state, &UIState.dismiss_help/1)

  # ── Close / dismiss ────────────────────────────────────────────────────────

  @doc "Returns from the agent view to the recorded editor context."
  @spec scope_close(state()) :: state()
  def scope_close(state), do: return_to_editor(state)

  @doc """
  Returns to the source line a provenance jump came from.

  Closes the loop for "jump from code into the agent": leaves the agent view,
  reopens the origin file, and places the cursor on the line the user pressed
  `SPC a W` on. No-op with a status message when there is no active jump.
  """
  @spec scope_provenance_return(state()) :: state()
  def scope_provenance_return(state) do
    case state.workspace.agent_ui.panel.transcript.provenance_jump do
      %ProvenanceJump{origin: {path, line}} ->
        state
        |> then(fn state ->
          TraditionalWorkflow.install_agent_panel(
            state,
            (&Panel.clear_provenance_jump/1).(state.workspace.agent_ui.panel)
          )
        end)
        |> return_to_editor()
        |> return_to_origin(path, line)

      _ ->
        NoticeWorkflow.publish(state, "No source line to return to")
    end
  end

  # After return_to_editor we are on the origin's file tab; place the cursor on
  # the origin line, reopening the file if it was closed in the meantime.
  @spec return_to_origin(state(), String.t(), non_neg_integer()) :: state()
  defp return_to_origin(state, path, line) do
    active = state.workspace.buffers.active

    if is_pid(active) and safe_file_path(active) == path do
      safe_move_to(active, {line, 0})
      state
    else
      open_origin_buffer(state, path, line)
    end
  end

  @spec open_origin_buffer(state(), String.t(), non_neg_integer()) :: state()
  defp open_origin_buffer(state, path, line) do
    case Enum.find_index(state.workspace.buffers.list, &(safe_file_path(&1) == path)) do
      nil ->
        case Commands.start_buffer(path, state.interaction.options_server) do
          {:ok, pid} ->
            state = Commands.add_buffer(state, pid)
            safe_move_to(pid, {line, 0})
            state

          {:error, _reason} ->
            NoticeWorkflow.publish(
              state,
              "Could not reopen #{Path.basename(path)}"
            )
        end

      idx ->
        state = MingaEditor.BufferActivation.activate(state, idx)
        safe_move_to(state.workspace.buffers.active, {line, 0})
        state
    end
  end

  @spec safe_move_to(pid(), {non_neg_integer(), non_neg_integer()}) :: :ok
  defp safe_move_to(buf, pos) do
    Buffer.move_to(buf, pos)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Dismisses active overlays or returns to the editor (ESC behavior)."
  @spec scope_dismiss_or_noop(state()) :: state()
  def scope_dismiss_or_noop(state), do: dismiss_agent_transient_or_return(state)

  @spec dismiss_agent_transient_or_return(state()) :: state()
  defp dismiss_agent_transient_or_return(state) do
    view = state.workspace.agent_ui.view
    panel = state.workspace.agent_ui.panel

    dismiss_agent_transient_or_return(state, view, panel)
  end

  @spec dismiss_agent_transient_or_return(state(), UIState.View.t(), Panel.t()) :: state()
  defp dismiss_agent_transient_or_return(state, %{help_visible: true}, _panel) do
    update_agent_ui(state, &UIState.dismiss_help/1)
  end

  defp dismiss_agent_transient_or_return(state, view, _panel) do
    if UIState.searching?(view) do
      update_agent_ui(state, &UIState.cancel_search/1)
    else
      dismiss_agent_prefix_or_modal(state, view)
    end
  end

  @spec dismiss_agent_prefix_or_modal(state(), UIState.View.t()) :: state()
  defp dismiss_agent_prefix_or_modal(state, view) do
    dismiss_agent_prefix(state, UIState.View.pending_prefix(view))
  end

  @spec dismiss_agent_prefix(state(), UIState.View.prefix()) :: state()
  defp dismiss_agent_prefix(state, nil) do
    panel = state.workspace.agent_ui.panel
    dismiss_agent_panel_or_modal(state, panel)
  end

  defp dismiss_agent_prefix(state, _prefix) do
    update_agent_ui(state, &UIState.clear_prefix/1)
  end

  @spec dismiss_agent_panel_or_modal(state(), Panel.t()) :: state()
  defp dismiss_agent_panel_or_modal(state, %{mention_completion: nil}) do
    dismiss_agent_modal_or_hover(state, state.shell_runtime.state.modal)
  end

  defp dismiss_agent_panel_or_modal(state, _panel) do
    update_agent_ui(state, &UIState.clear_mention_completion/1)
  end

  @spec dismiss_agent_modal_or_hover(state(), ModalOverlay.t()) :: state()
  defp dismiss_agent_modal_or_hover(state, :none) do
    dismiss_agent_hover_or_input(state, state.shell_runtime.state.hover_popup)
  end

  defp dismiss_agent_modal_or_hover(state, _modal),
    do: MingaEditor.Shell.Traditional.ModalWorkflow.dismiss(state)

  @spec dismiss_agent_hover_or_input(state(), term()) :: state()
  defp dismiss_agent_hover_or_input(state, nil), do: dismiss_agent_input_or_return(state)

  defp dismiss_agent_hover_or_input(state, _hover),
    do: MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss(state)

  @spec dismiss_agent_input_or_return(state()) :: state()
  defp dismiss_agent_input_or_return(state) do
    if state.workspace.agent_ui.panel.input_focused do
      scope_unfocus_input(state)
    else
      return_to_editor(state)
    end
  end

  # ── Clear ──────────────────────────────────────────────────────────────────

  @doc "Clears the chat display without losing conversation history."
  @spec scope_clear_chat(state()) :: state()
  def scope_clear_chat(state) do
    clear_chat_display(state)
  end

  # ── Insert mode commands ───────────────────────────────────────────────────

  @doc "Submits the prompt or inserts a newline (context-dependent)."
  @spec scope_submit_or_newline(state()) :: state()
  def scope_submit_or_newline(state), do: submit_prompt(state)

  @doc """
  CUA Enter behavior: focus input if not focused, submit if focused.

  CUA mode has a single trie for all agent states (no normal/insert
  distinction). This command provides the natural Enter behavior:
  first Enter focuses the input field, subsequent Enter submits.
  """
  @spec scope_focus_or_submit(state()) :: state()
  def scope_focus_or_submit(state) do
    panel = state.workspace.agent_ui.panel

    if panel.input_focused do
      submit_prompt(state)
    else
      scope_focus_input(state)
    end
  end

  @doc "Inserts a newline in the input field."
  @spec scope_insert_newline(state()) :: state()
  def scope_insert_newline(state) do
    update_agent_ui(state, &PromptBuffer.insert_newline/1)
  end

  @doc "Submits if input has text, aborts if agent is active."
  @spec scope_submit_or_abort(state()) :: state()
  def scope_submit_or_abort(state) do
    if PromptBuffer.prompt_text(state.workspace.agent_ui.panel) != "" do
      submit_prompt(state)
    else
      abort_if_active(state)
    end
  end

  @doc "Moves cursor up in input or recalls history."
  @spec scope_input_up(state()) :: state()
  def scope_input_up(state) do
    panel = state.workspace.agent_ui.panel
    {line, _col} = PromptBuffer.input_cursor(panel)

    if line == 0 do
      update_agent_ui(state, &PromptBuffer.history_prev/1)
    else
      update_agent_ui(state, &PromptBuffer.move_cursor_up/1)
    end
  end

  @doc "Moves cursor down in input or advances history."
  @spec scope_input_down(state()) :: state()
  def scope_input_down(state) do
    panel = state.workspace.agent_ui.panel
    {line, _col} = PromptBuffer.input_cursor(panel)
    max_line = PromptBuffer.input_line_count(panel) - 1

    if line >= max_line do
      update_agent_ui(state, &PromptBuffer.history_next/1)
    else
      update_agent_ui(state, &PromptBuffer.move_cursor_down/1)
    end
  end

  @doc "Self-insert: adds a character to the input field."
  @spec scope_self_insert(state(), String.t()) :: state()
  def scope_self_insert(state, char) do
    input_char(state, char)
  end

  @doc "Saves the active buffer (Ctrl+S from agent insert mode)."
  @spec scope_save_buffer(state()) :: state()
  def scope_save_buffer(state) do
    # Delegate to the standard save command
    Commands.execute(state, :save)
  end

  @doc "Aborts agent operation if one is active."
  @spec scope_abort_if_active(state()) :: state()
  def scope_abort_if_active(state) do
    if MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state).runtime.status in [
         :thinking,
         :tool_executing
       ] do
      abort_agent(state)
    else
      state
    end
  end

  # Mention completion handling delegated to AgentSubStates.

  @spec handle_mention_key(state(), non_neg_integer(), non_neg_integer()) :: state()
  def handle_mention_key(state, cp, mods), do: AgentSubStates.handle_mention_key(state, cp, mods)

  # ── Diff review commands ───────────────────────────────────────────────────

  @spec scope_accept_hunk(state()) :: state()
  def scope_accept_hunk(state), do: AgentSubStates.accept_hunk(state)

  @spec scope_reject_hunk(state()) :: state()
  def scope_reject_hunk(state), do: AgentSubStates.reject_hunk(state)

  @spec scope_accept_all_hunks(state()) :: state()
  def scope_accept_all_hunks(state), do: AgentSubStates.accept_all_hunks(state)

  @spec scope_reject_all_hunks(state()) :: state()
  def scope_reject_all_hunks(state), do: AgentSubStates.reject_all_hunks(state)

  # ── Tool approval commands ─────────────────────────────────────────────────

  @spec scope_approve_tool(state()) :: state()
  def scope_approve_tool(state), do: AgentSubStates.approve_tool(state)

  @spec scope_trust_tool_session(state()) :: state()
  def scope_trust_tool_session(state), do: AgentSubStates.trust_tool_session(state)

  @spec scope_trust_tool_turn(state()) :: state()
  def scope_trust_tool_turn(state), do: AgentSubStates.trust_tool_turn(state)

  @spec scope_deny_tool(state()) :: state()
  def scope_deny_tool(state), do: AgentSubStates.deny_tool(state)

  # ── @-mention trigger ─────────────────────────────────────────────────────

  @spec scope_trigger_mention(state()) :: state()
  def scope_trigger_mention(state), do: AgentSubStates.trigger_mention(state)

  @spec scope_trigger_slash_completion(state()) :: state()
  def scope_trigger_slash_completion(state), do: AgentSubStates.trigger_slash_completion(state)

  @spec open_code_block(state(), String.t(), String.t()) :: state()
  def open_code_block(state, language, content),
    do: AgentSession.open_code_block(state, language, content)

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec safe_recall_queues(pid()) ::
          {[String.t() | [ReqLLM.Message.ContentPart.t()]],
           [String.t() | [ReqLLM.Message.ContentPart.t()]]}
          | {:error, :saved_draft_required}
  defp safe_recall_queues(session) do
    Session.recall_queues(session)
  catch
    :exit, _ -> {[], []}
  end

  @spec queue_recall_unavailable(state()) :: state()
  defp queue_recall_unavailable(state),
    do:
      NoticeWorkflow.publish(
        state,
        "Open the saved composer to recall its queued input. The queue was kept."
      )

  @spec restore_queued_to_prompt(state(), [String.t() | [ReqLLM.Message.ContentPart.t()]]) ::
          state()
  defp restore_queued_to_prompt(state, all_queued) do
    current_text = PromptBuffer.prompt_text(state.workspace.agent_ui.panel)
    combined = Session.combine_queue_entries_to_text(all_queued)

    restored =
      if current_text != "",
        do: combined <> "\n\n" <> current_text,
        else: combined

    update_agent_ui(state, &PromptBuffer.set_prompt_text(&1, restored))
  end

  @spec do_dequeue_to_editor(state(), [String.t() | [ReqLLM.Message.ContentPart.t()]]) ::
          state()
  defp do_dequeue_to_editor(state, []),
    do: NoticeWorkflow.publish(state, "No queued messages")

  defp do_dequeue_to_editor(state, all_queued) do
    count = Enum.count(all_queued)
    label = if count == 1, do: "message", else: "messages"
    state = restore_queued_to_prompt(state, all_queued)

    NoticeWorkflow.publish(
      state,
      "Restored #{count} queued #{label} to editor"
    )
  end

  @spec update_agent_ui(state(), (UIState.t() -> UIState.t())) :: state()
  defp update_agent_ui(state, fun),
    do:
      TraditionalWorkflow.install_agent_ui(
        state,
        fun.(state.workspace.agent_ui)
      )

  @spec update_preview(state(), (Preview.t() -> Preview.t())) :: state()
  defp update_preview(state, fun) do
    view = state.workspace.agent_ui.view
    updated_view = MingaEditor.Agent.UIState.View.replace_preview(view, fun.(view.preview))
    TraditionalWorkflow.install_agent_view(state, updated_view)
  end

  @spec panel_height(state()) :: non_neg_integer()
  defp panel_height(state) do
    div(state.frontend.terminal_viewport.rows * 35, 100)
  end

  @spec abort_if_active(state()) :: state()
  defp abort_if_active(state) do
    if MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state).runtime.status in [
         :thinking,
         :tool_executing
       ] do
      abort_agent(state)
    else
      state
    end
  end

  @spec scroll_context(state()) :: TranscriptProjection.Index.position() | nil
  defp scroll_context(state) do
    panel = state.workspace.agent_ui.panel
    total = TranscriptProjection.line_count(panel.transcript)
    target = Minga.Editing.resolve_scroll(panel.scroll, total, 1)
    TranscriptProjection.line_at(panel.transcript, target)
  end

  @spec copy_to_clipboard(state(), String.t(), String.t()) :: state()
  defp copy_to_clipboard(state, text, label) do
    case Clipboard.write(text) do
      :ok ->
        if Runtime.active_session(state.shell_runtime) do
          Session.add_system_message(
            Runtime.active_session(state.shell_runtime),
            "Copied #{label} to clipboard"
          )
        end

        update_agent_ui(state, &UIState.push_toast(&1, "Copied #{label}", :info))

      _error ->
        if Runtime.active_session(state.shell_runtime) do
          Session.add_system_message(
            Runtime.active_session(state.shell_runtime),
            "Clipboard write failed",
            :error
          )
        end

        update_agent_ui(state, &UIState.push_toast(&1, "Clipboard write failed", :error))
    end

    state
  end

  @spec code_block_for_scroll(Message.t(), non_neg_integer(), [Markdown.code_block()]) ::
          String.t()
  defp code_block_for_scroll(_message, _offset, []), do: ""

  defp code_block_for_scroll(message, offset, blocks) do
    index = code_block_index_for_scroll(message, offset, blocks)
    Enum.at(blocks, index, hd(blocks)).content
  end

  @spec code_block_index_for_scroll(Message.t(), non_neg_integer(), [Markdown.code_block()]) ::
          non_neg_integer()
  defp code_block_index_for_scroll(_message, _offset, []), do: 0

  defp code_block_index_for_scroll(message, offset, blocks) do
    profile = Transcript.line_profile(message)

    {block, _in_code?} =
      Enum.reduce(0..offset, {0, false}, fn local_line, {block, in_code?} ->
        case Transcript.line_type_at(profile, local_line) do
          :code -> {block, true}
          _other when in_code? -> {block + 1, false}
          _other -> {block, false}
        end
      end)

    min(block, length(blocks) - 1)
  end

  # Delegates to EditorState shared helper.
  defp scroll_agent_chat_window(state, delta),
    do: %{
      state
      | workspace: MingaEditor.Session.State.scroll_agent_chat_window(state.workspace, delta)
    }

  # Commands callable from any keymap scope. This includes:
  # - Toggle/lifecycle/session management (invoked from editor scope leader keys)
  # - Input commands used in the side panel (AgentPanel resolves from the
  #   :agent trie but keymap_scope stays :editor, so these can't require :agent)
  @global_agent_commands [
    {:toggle_agentic_view, "Toggle agent split pane", :toggle_agentic_view},
    {:toggle_agent_split, "Toggle agent split", :toggle_agent_split},
    {:cycle_agent_tabs, "Cycle agent tabs (opens split if none)", :cycle_agent_tabs},
    {:agent_abort, "Abort current AI agent turn", :abort_agent},
    {:agent_stop_session, "Stop AI agent session", :stop_current_session},
    {:agent_new_session, "New local agent workspace", :new_agent_session},
    {:agent_start_session_picker, "Pick agent session location", :start_session_picker},
    {:agent_cycle_thinking, "Cycle AI thinking level", :cycle_thinking_level},
    {:agent_thinking_off, "Set AI thinking level to off", :set_thinking_off},
    {:agent_thinking_low, "Set AI thinking level to low", :set_thinking_low},
    {:agent_thinking_medium, "Set AI thinking level to medium", :set_thinking_medium},
    {:agent_thinking_high, "Set AI thinking level to high", :set_thinking_high},
    {:agent_clear_history, "Clear all saved agent sessions", :clear_session_history},
    # Input commands shared between editor scope (side panel) and agent scope
    {:agent_scroll_half_down, "Scroll agent chat down", :scroll_chat_down},
    {:agent_scroll_half_up, "Scroll agent chat up", :scroll_chat_up},
    {:agent_submit_or_newline, "Submit or newline", :scope_submit_or_newline},
    {:agent_insert_newline, "Insert newline in agent input", :scope_insert_newline},
    {:agent_submit_or_abort, "Submit or abort agent", :scope_submit_or_abort},
    {:agent_ctrl_c, "Normal mode (also aborts while streaming)", :scope_ctrl_c},
    {:agent_queue_follow_up, "Queue as follow-up or submit if idle", :scope_queue_follow_up},
    {:agent_dequeue, "Dequeue messages back to editor", :scope_dequeue},
    {:agent_toggle_help, "Toggle agent help", :scope_toggle_help},
    {:agent_dismiss_help, "Close agent help", :scope_dismiss_help},
    {:agent_input_backspace, "Agent input backspace", :input_backspace},
    {:agent_input_up, "Agent input up", :scope_input_up},
    {:agent_input_down, "Agent input down", :scope_input_down},
    {:agent_save_buffer, "Save buffer from agent", :scope_save_buffer},
    {:agent_input_to_normal, "Agent input to normal mode", :input_to_normal},
    {:agent_unfocus_and_quit, "Unfocus input and quit", :scope_unfocus_and_quit},
    {:agent_clear_chat, "Clear agent chat", :scope_clear_chat},
    {:agent_trigger_mention, "Trigger agent mention", :scope_trigger_mention}
  ]

  # Commands that require `keymap_scope == :agent`. These only make sense
  # in the full agent view (navigation, fold, copy, diff review, panel
  # management). The dispatch layer (Commands.execute/2) enforces this
  # via the `scope` field, so individual command functions no
  # longer need internal guards.
  @scoped_agent_commands [
    {:agent_toggle_all_collapse, "Toggle all collapsible agent blocks",
     :scope_toggle_all_collapse},
    {:agent_next_code_block, "Next code block", :scope_next_code_block},
    {:agent_prev_code_block, "Previous code block", :scope_prev_code_block},
    {:agent_copy_code_block, "Copy code block", :scope_copy_code_block},
    {:agent_copy_message, "Copy message", :scope_copy_message},
    {:agent_open_code_block, "Open code block", :scope_open_code_block},
    {:agent_apply_code_block, "Apply code block to file", :scope_apply_code_block},
    {:agent_pin_message, "Pin/unpin message at cursor", :scope_pin_message},
    {:agent_focus_input, "Focus agent input", :scope_focus_input},
    {:agent_focus_or_submit, "Focus input or submit", :scope_focus_or_submit},
    {:agent_unfocus_input, "Unfocus agent input", :scope_unfocus_input},
    {:agent_grow_panel, "Grow agent panel", :scope_grow_panel},
    {:agent_shrink_panel, "Shrink agent panel", :scope_shrink_panel},
    {:agent_reset_panel, "Reset agent panel size", :scope_reset_panel},
    {:agent_switch_focus, "Switch agent focus", :scope_switch_focus},
    {:agent_start_search, "Start agent search", :scope_start_search},
    {:agent_next_search_match, "Next agent search match", :scope_next_search_match},
    {:agent_prev_search_match, "Previous agent search match", :scope_prev_search_match},
    {:agent_session_switcher, "Agent session switcher", :scope_session_switcher},
    {:agent_close, "Return to editor", :scope_close},
    {:agent_provenance_return, "Return to provenance source line", :scope_provenance_return},
    {:agent_dismiss_or_noop, "Dismiss agent or no-op", :scope_dismiss_or_noop},
    {:agent_accept_hunk, "Accept agent hunk", :scope_accept_hunk},
    {:agent_reject_hunk, "Reject agent hunk", :scope_reject_hunk},
    {:agent_accept_all_hunks, "Accept all agent hunks", :scope_accept_all_hunks},
    {:agent_reject_all_hunks, "Reject all agent hunks", :scope_reject_all_hunks},
    {:agent_approve_tool, "Approve agent tool", :scope_approve_tool},
    {:agent_trust_tool_session, "Trust agent tool for session", :scope_trust_tool_session},
    {:agent_trust_tool_turn, "Trust agent tool for turn", :scope_trust_tool_turn},
    {:agent_deny_tool, "Deny agent tool", :scope_deny_tool}
  ]

  @impl Minga.Command.Provider
  def __commands__ do
    global =
      Enum.map(@global_agent_commands, fn {cmd_name, desc, fun_name} ->
        %Minga.Command{
          name: cmd_name,
          description: desc,
          execute: fn state -> apply(__MODULE__, fun_name, [state]) end
        }
      end)

    scoped =
      Enum.map(@scoped_agent_commands, fn {cmd_name, desc, fun_name} ->
        %Minga.Command{
          name: cmd_name,
          description: desc,
          scope: :agent,
          execute: fn state -> apply(__MODULE__, fun_name, [state]) end
        }
      end)

    dispatched = global ++ scoped

    pickers = [
      %Minga.Command{
        name: :agent_pick_model,
        description: "Pick AI agent model",
        requires_buffer: false,
        execute: &MingaEditor.UI.Picker.AgentModelSource.open/1
      },
      %Minga.Command{
        name: :agent_retained_history,
        description: "Read retained Agent messages",
        requires_buffer: false,
        execute: &MingaEditor.UI.Picker.AgentHistorySource.open/1
      },
      %Minga.Command{
        name: :agent_checklist,
        description: "Inspect Agent checklist",
        requires_buffer: false,
        execute: &MingaEditor.UI.Picker.AgentChecklistSource.open/1
      },
      %Minga.Command{
        name: :agent_attach_selection,
        description: "Attach selected text to an Agent draft",
        execute: &MingaEditor.UI.Picker.SelectionAttachmentTargetSource.open/1
      },
      %Minga.Command{
        name: :agent_attach_buffer,
        description: "Attach current buffer to an Agent draft",
        execute: &MingaEditor.UI.Picker.SelectionAttachmentTargetSource.open_buffer/1
      },
      %Minga.Command{
        name: :agent_attach_file,
        description: "Attach a project file to an Agent draft",
        requires_buffer: false,
        execute: &MingaEditor.UI.Picker.FileAttachmentSource.open/1
      },
      %Minga.Command{
        name: :agent_attach_diagnostics,
        description: "Attach current file diagnostics to an Agent draft",
        execute: &MingaEditor.UI.Picker.DiagnosticAttachmentSource.open/1
      },
      %Minga.Command{
        name: :agent_draft_attachments,
        description: "Inspect Agent draft attachments",
        requires_buffer: false,
        execute: &MingaEditor.UI.Picker.AgentDraftAttachmentSource.open/1
      },
      %Minga.Command{
        name: :agent_queued_inputs,
        description: "Inspect queued Agent inputs",
        requires_buffer: false,
        execute: &MingaEditor.UI.Picker.AgentQueuedInputSource.open/1
      },
      %Minga.Command{
        name: :agent_answer_question,
        description: "Answer Agent question",
        requires_buffer: false,
        execute: &MingaEditor.UI.Picker.AgentQuestionSource.open/1
      },
      %Minga.Command{
        name: :agent_retry_start,
        description: "Retry the failed Agent start",
        requires_buffer: false,
        execute: &AgentSession.retry_start/1
      },
      %Minga.Command{
        name: :agent_start_remedy,
        description: "Run the failed Agent start's remedy",
        requires_buffer: false,
        execute: &AgentSession.run_start_remedy/1
      },
      %Minga.Command{
        name: :agent_pick_thinking,
        description: "Pick AI thinking level",
        requires_buffer: false,
        execute: &pick_thinking_level/1
      },
      %Minga.Command{
        name: :agent_session_rename,
        description: "Rename Agent session",
        requires_buffer: false,
        execute: &MingaEditor.UI.Prompt.AgentSessionRename.open/1
      },
      %Minga.Command{
        name: :agent_session_history,
        description: "Resume agent session",
        requires_buffer: false,
        execute: fn state ->
          MingaEditor.UI.Picker.AgentSessionSource.open(state, %{persisted_only: true})
        end
      }
    ]

    dispatched ++ pickers
  end
end
