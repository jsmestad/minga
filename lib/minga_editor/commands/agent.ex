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
  alias MingaAgent.Session
  alias MingaAgent.SessionStore
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.ProvenanceJump
  alias MingaEditor.Agent.SlashCommand
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.View.Preview
  alias Minga.Buffer
  alias Minga.Clipboard
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Commands.AgentSubStates

  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Input.AgentPanel

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @type prompt_readiness ::
          :no_model | :credentials_missing | :starting | {:startup_failed, String.t()} | :ready
  @type prompt_submit_status :: :ready | {:blocked, String.t()}

  @doc "Legacy alias for `toggle_agent_split/1`."
  @spec toggle_agentic_view(state()) :: state()
  def toggle_agentic_view(state), do: toggle_agent_split(state)

  @doc """
  Toggles an agent chat split pane in the window tree.

  When no agent pane exists: ensures an agent session is running,
  then applies the `:agent_right` layout preset (file left, agent
  chat right). When an agent pane exists: removes it and restores
  the single-window layout.

  The agent state lives in a background agent tab (created if needed).
  """
  @spec toggle_agent_split(state()) :: state()
  def toggle_agent_split(state) do
    case EditorState.active_tab_kind(state) do
      :agent ->
        return_to_editor(state)

      _ ->
        # On file tab: ensure agent tab exists, record the return target, and switch to it.
        state = ensure_agent_state(state)
        return_target = build_return_target(state)

        case find_agent_tab(state) do
          %Tab{id: agent_id} ->
            # Switch first, then ensure a session exists. Shell.Runtime.active_session/1
            # is per-tab, so the start-if-missing check must run after the
            # switch — otherwise it would always see nil from the file tab.
            state
            |> EditorState.switch_tab(agent_id)
            |> maybe_start_session()
            |> activate_agent_view(return_target)

          nil ->
            state
        end
    end
  end

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
    origin = capture_origin(state)
    state = ensure_agent_state(state)
    return_target = build_return_target(state)

    case find_agent_tab(state) do
      %Tab{id: agent_id} ->
        state = state |> EditorState.switch_tab(agent_id) |> maybe_start_session()

        case Runtime.active_session(state.shell_runtime) do
          nil ->
            NoticeWorkflow.publish(
              state,
              "No agent session available"
            )

          session_pid ->
            load_persisted_session(session_pid, session_id)
            state = arm_provenance_jump(state, session_pid, tool_call_id, origin)
            activate_agent_view(state, return_target)
        end

      nil ->
        NoticeWorkflow.publish(state, "Could not open agent")
    end
  end

  @spec load_persisted_session(pid(), String.t()) :: :ok
  defp load_persisted_session(session_pid, session_id) do
    Session.load_session(session_pid, session_id)
    :ok
  catch
    :exit, _ -> :ok
  end

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

  @spec arm_provenance_jump(state(), pid(), String.t() | nil, ProvenanceJump.origin() | nil) ::
          state()
  defp arm_provenance_jump(state, _session_pid, nil, _origin), do: state

  defp arm_provenance_jump(state, session_pid, tool_call_id, origin) do
    with pairs when is_list(pairs) <- safe_messages_with_ids(session_pid),
         target_id when is_integer(target_id) <-
           Transcript.turn_anchor_id(pairs, tool_call_id) do
      jump = ProvenanceJump.request(target_id, origin)

      TraditionalWorkflow.install_agent_panel(
        state,
        (&Panel.set_provenance_jump(&1, jump)).(state.workspace.agent_ui.panel)
      )
    else
      # Dead session (nil pairs) or tool call not in the transcript (nil anchor):
      # skip the jump and open at the bottom. A non-nil unexpected shape should
      # surface as a WithClauseError rather than silently degrade.
      nil -> state
    end
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

  @spec safe_messages_with_ids(pid()) :: [{pos_integer(), term()}] | nil
  defp safe_messages_with_ids(session_pid) do
    Session.messages_with_ids(session_pid)
  catch
    :exit, _ -> nil
  end

  @spec ensure_agent_state(state()) :: state()
  defp ensure_agent_state(state), do: ensure_agent_tab(state)

  @spec ensure_agent_tab(state()) :: state()
  defp ensure_agent_tab(state) do
    case find_agent_tab(state) do
      nil ->
        win_id = 1
        rows = max(state.frontend.terminal_viewport.rows, 1)
        cols = max(state.frontend.terminal_viewport.cols, 1)
        agent_window = Window.new_agent_chat(win_id, rows, cols)

        windows = %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => agent_window},
          active: win_id,
          next_id: win_id + 1
        }

        # Build complete context with all @per_tab_fields populated.
        context = EditorState.build_agent_tab_defaults(state, windows)

        # Create agent tab in the background (don't switch to it).
        # Group creation happens later in start_agent_session when the session pid is available.
        tab_bar = state.shell_runtime.state.tab_bar || TabBar.new(Tab.new_file(1, "File"))
        original_active_id = tab_bar.active_id
        {tb, new_tab} = TabBar.add(tab_bar, :agent, "Agent")
        tb = TabBar.update_context(tb, new_tab.id, context)

        # Switch back to the original active tab
        tb = TabBar.switch_to(tb, original_active_id)

        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.set_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              tb
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      _existing ->
        state
    end
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
    case EditorState.active_tab(state) do
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

  @doc "Returns from the agent view to the recorded editor context without stopping the session."
  @spec return_to_editor(state()) :: state()
  def return_to_editor(state) do
    return_target = state.workspace.agent_ui.view |> UIState.View.return_target()

    case target_file_tab_id(state.shell_runtime.state.tab_bar, return_target) do
      {:exact, id} ->
        state
        |> mark_agent_view_inactive()
        |> EditorState.switch_tab(id)
        |> restore_return_keymap_scope(return_target)

      {:fallback, id} ->
        state
        |> mark_agent_view_inactive()
        |> EditorState.switch_tab(id)

      nil ->
        restore_return_target_without_tab(state, return_target)
    end
  end

  @spec target_file_tab_id(TabBar.t() | nil, UIState.View.return_target() | nil) ::
          {:exact, pos_integer()} | {:fallback, pos_integer()} | nil
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
  defp restore_return_target_without_tab(state, nil) do
    state
    |> mark_agent_view_inactive()
    |> then(fn state ->
      %{state | workspace: MingaEditor.Session.State.set_keymap_scope(state.workspace, :editor)}
    end)
    |> NoticeWorkflow.publish("No file tabs in this workspace")
  end

  defp restore_return_target_without_tab(state, return_target) do
    state
    |> mark_agent_view_inactive()
    |> restore_workspace_return_target(return_target)
    |> restore_prompt_focus(return_target.prompt_focused)
    |> NoticeWorkflow.publish("No file tabs in this workspace")
  end

  @spec restore_workspace_return_target(state(), UIState.View.return_target()) :: state()
  defp restore_workspace_return_target(state, return_target) do
    workspace =
      state.workspace
      |> SessionState.set_keymap_scope(return_target.keymap_scope)
      |> SessionState.set_windows(return_target.windows)
      |> SessionState.set_file_tree(return_target.file_tree)
      |> restore_return_target_buffer(return_target.active_buffer)

    %{state | workspace: workspace}
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

  @doc "Submits the current input text as a prompt."
  @spec submit_prompt(state()) :: state()
  def submit_prompt(state) do
    panel = state.workspace.agent_ui.panel

    submit_prompt(
      state,
      panel,
      PromptBuffer.input_empty?(panel),
      Runtime.active_session(state.shell_runtime)
    )
  end

  @spec submit_prompt(state(), Panel.t(), boolean(), pid() | nil) :: state()
  defp submit_prompt(state, _panel, true, _session), do: state

  defp submit_prompt(state, panel, false, nil) do
    case prompt_readiness(state, panel, nil) do
      :no_model ->
        NoticeWorkflow.publish(state, no_model_status())

      _readiness ->
        NoticeWorkflow.publish(
          state,
          "No agent session, try closing and reopening the panel"
        )
    end
  end

  defp submit_prompt(state, panel, false, _session) do
    text = PromptBuffer.prompt_text(panel)
    submit_prompt_text(state, text, SlashCommand.slash_command?(text))
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
    case prompt_submit_status(state, panel) do
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
        deliver_prompt(state, resolved)

      {:error, msg} ->
        NoticeWorkflow.publish(state, msg)
    end
  end

  # Clears the input and resets diff baselines after a prompt is submitted.
  @spec clear_input_after_submit(state()) :: state()
  defp clear_input_after_submit(state) do
    state = update_agent_ui(state, &PromptBuffer.clear_input_and_scroll/1)

    TraditionalWorkflow.install_agent_ui(
      state,
      (fn _ ->
         UIState.clear_baselines(state.workspace.agent_ui)
       end).(state.workspace.agent_ui)
    )
  end

  # Sends the resolved content to the LLM and handles steering queue feedback.
  @spec deliver_prompt(state(), String.t() | [ReqLLM.Message.ContentPart.t()]) :: state()
  defp deliver_prompt(state, resolved) do
    case AgentSession.send_prompt_pid(
           Runtime.active_session(state.shell_runtime),
           resolved
         ) do
      :ok ->
        clear_input_after_submit(state)

      {:queued, :steering} ->
        state
        |> clear_input_after_submit()
        |> update_agent_ui(&UIState.push_toast(&1, "⏳ Queued (steer). Ctrl-C to cancel.", :info))

      {:error, :provider_not_ready} ->
        NoticeWorkflow.publish(state, provider_starting_status())

      {:error, :credentials_not_configured} ->
        NoticeWorkflow.publish(state, credentials_missing_status())

      {:error, msg} when is_binary(msg) ->
        NoticeWorkflow.publish(state, msg)

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Agent error: #{inspect(reason)}"
        )
    end
  end

  @spec send_follow_up_to_llm(state(), String.t()) :: state()
  defp send_follow_up_to_llm(state, text) do
    if remote_session_disconnected?(state) do
      NoticeWorkflow.publish(
        state,
        "Session disconnected. Your prompt will be preserved."
      )
    else
      panel = state.workspace.agent_ui.panel

      case prompt_submit_status(state, panel) do
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

  @spec resolve_and_deliver_follow_up(state(), String.t(), String.t()) :: state()
  defp resolve_and_deliver_follow_up(state, text, model) do
    case resolve_prompt_for_session(state, text, model) do
      {:ok, resolved} ->
        deliver_follow_up(state, resolved)

      {:error, msg} ->
        NoticeWorkflow.publish(state, msg)
    end
  end

  @spec prompt_submit_status(state(), Panel.t()) :: prompt_submit_status()
  defp prompt_submit_status(state, panel) do
    if remote_session?(state) do
      :ready
    else
      state
      |> prompt_readiness(panel, Runtime.active_session(state.shell_runtime))
      |> prompt_readiness_submit_status()
    end
  end

  @spec prompt_readiness(state(), Panel.t(), pid() | nil) :: prompt_readiness()
  defp prompt_readiness(state, %Panel{} = panel, session) do
    if model_configured?(panel.model_name) do
      prompt_readiness_with_model(state, panel, session)
    else
      :no_model
    end
  end

  @spec prompt_readiness_with_model(state(), Panel.t(), pid() | nil) :: prompt_readiness()
  defp prompt_readiness_with_model(state, %Panel{}, session) when is_pid(session) do
    prompt_readiness_with_credentials(state, session)
  end

  defp prompt_readiness_with_model(_state, %Panel{credentials_configured: false}, nil),
    do: :credentials_missing

  defp prompt_readiness_with_model(state, %Panel{credentials_configured: true}, nil) do
    prompt_readiness_with_credentials(state, nil)
  end

  @spec prompt_readiness_with_credentials(state(), pid() | nil) :: prompt_readiness()
  defp prompt_readiness_with_credentials(_state, nil), do: :ready

  defp prompt_readiness_with_credentials(_state, session) when is_pid(session) do
    case Session.get_provider(session) do
      provider when is_pid(provider) -> :ready
      _provider -> providerless_prompt_readiness(session)
    end
  end

  @spec providerless_prompt_readiness(pid()) :: prompt_readiness()
  defp providerless_prompt_readiness(session) do
    case Session.editor_snapshot(session) do
      %{credentials_configured: false} -> :credentials_missing
      %{error: error} when is_binary(error) and error != "" -> {:startup_failed, error}
      _snapshot -> :starting
    end
  end

  @spec model_configured?(String.t()) :: boolean()
  defp model_configured?(model) when model in ["", "unknown"], do: false
  defp model_configured?(model), do: model != AgentConfig.unconfigured_model()

  @spec prompt_readiness_submit_status(prompt_readiness()) :: prompt_submit_status()
  defp prompt_readiness_submit_status(:ready), do: :ready
  defp prompt_readiness_submit_status(:no_model), do: {:blocked, no_model_status()}

  defp prompt_readiness_submit_status(:credentials_missing),
    do: {:blocked, credentials_missing_status()}

  defp prompt_readiness_submit_status(:starting), do: {:blocked, provider_starting_status()}

  defp prompt_readiness_submit_status({:startup_failed, error}) do
    {:blocked, provider_startup_failed_status(error)}
  end

  @spec no_model_status() :: String.t()
  defp no_model_status do
    "No model configured. Your prompt was preserved. Run /auth, /login, or pick a configured model."
  end

  @spec credentials_missing_status() :: String.t()
  defp credentials_missing_status do
    "No provider credentials are configured for this model. Your prompt was preserved. Run /auth or /login to set one up."
  end

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

  @spec resolve_prompt_for_session(state(), String.t(), String.t()) ::
          {:ok, String.t() | [ReqLLM.Message.ContentPart.t()]} | {:error, String.t()}
  defp resolve_prompt_for_session(state, text, model) do
    if remote_session?(state) do
      {:ok, text}
    else
      resolve_mentions(text, model: model)
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

  @spec deliver_follow_up(state(), String.t() | [ReqLLM.Message.ContentPart.t()]) :: state()
  defp deliver_follow_up(state, resolved) do
    case Session.queue_follow_up(
           Runtime.active_session(state.shell_runtime),
           resolved
         ) do
      :ok ->
        update_agent_ui(state, &PromptBuffer.clear_input_and_scroll/1)

      {:queued, :follow_up} ->
        state
        |> update_agent_ui(&PromptBuffer.clear_input_and_scroll/1)
        |> update_agent_ui(
          &UIState.push_toast(&1, "⏳ Queued (follow-up). Ctrl-C to cancel.", :info)
        )

      {:error, :provider_not_ready} ->
        NoticeWorkflow.publish(state, provider_starting_status())

      {:error, :credentials_not_configured} ->
        NoticeWorkflow.publish(state, credentials_missing_status())

      {:error, msg} when is_binary(msg) ->
        NoticeWorkflow.publish(state, msg)

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Agent error: #{inspect(reason)}"
        )
    end
  end

  @spec resolve_mentions(String.t(), keyword()) ::
          {:ok, String.t()} | {:ok, [ReqLLM.Message.ContentPart.t()]} | {:error, String.t()}
  defp resolve_mentions(text, opts) do
    root = project_root()
    FileMention.resolve_prompt(text, root, opts)
  end

  @spec project_root() :: String.t()
  defp project_root, do: Minga.Project.resolve_root()

  @doc "Clears the chat display without affecting conversation history."
  @spec clear_chat_display(state()) :: state()
  def clear_chat_display(state) do
    msg_count =
      if Runtime.active_session(state.shell_runtime) do
        try do
          Enum.count(Session.messages(Runtime.active_session(state.shell_runtime)))
        catch
          :exit, _ -> 0
        end
      else
        0
      end

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
  Aborts the current agent operation and restores any queued messages to the prompt input.

  Queued steering and follow-up messages are recalled from the Session and placed
  back in the prompt buffer so nothing is lost.
  """
  @spec abort_agent(state()) :: state()
  def abort_agent(state) do
    case Runtime.active_session(state.shell_runtime) do
      nil ->
        state

      session ->
        {steering, follow_up} = safe_recall_queues(session)

        try do
          Session.abort(session)
        catch
          :exit, _ -> :ok
        end

        restore_queued_to_prompt(state, steering ++ follow_up)
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
        {steering, follow_up} = safe_recall_queues(session)
        do_dequeue_to_editor(state, steering ++ follow_up)
    end
  end

  @doc "Queues the current input as a follow-up; submits normally when agent is idle."
  @spec scope_queue_follow_up(state()) :: state()
  def scope_queue_follow_up(state) do
    panel = state.workspace.agent_ui.panel

    cond do
      PromptBuffer.input_empty?(panel) ->
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
        text = PromptBuffer.prompt_text(panel)

        if SlashCommand.slash_command?(text) do
          state = clear_submitted_slash_input(state, text)
          execute_slash_command(state, text)
        else
          send_follow_up_to_llm(state, text)
        end

      true ->
        # Agent is idle: Ctrl+Enter behaves like regular Enter.
        submit_prompt(state)
    end
  end

  @doc "Dequeues all pending messages back into the prompt input without aborting."
  @spec scope_dequeue(state()) :: state()
  def scope_dequeue(state), do: dequeue_to_editor(state)

  @doc """
  Context-sensitive Ctrl-C handler.

  During streaming: aborts the agent and restores queued messages to the prompt.
  When idle in insert mode: returns to normal mode (vim convention).
  When idle in normal mode: no-op.
  """
  @spec scope_ctrl_c(state()) :: state()
  def scope_ctrl_c(state) do
    case MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state).runtime.status do
      status when status in [:thinking, :tool_executing] -> abort_agent(state)
      :error -> restart_agent_provider(state)
      _status -> input_to_normal(state)
    end
  end

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
    state
    |> create_active_agent_tab()
    |> reset_agent_state_for_new_session()
    |> AgentLifecycle.setup_agent_highlight()
    |> AgentSession.start_agent_session(recover_interrupted_work?: false)
  end

  @spec reset_agent_state_for_new_session(state()) :: state()
  defp reset_agent_state_for_new_session(state) do
    old_panel = state.workspace.agent_ui.panel

    state = TraditionalWorkflow.install_agent_state(state, %AgentState{})

    agent_ui =
      UIState.new()
      |> UIState.set_thinking_level(old_panel.thinking_level)

    TraditionalWorkflow.install_agent_ui(state, agent_ui)
  end

  @spec create_active_agent_tab(state()) :: state()
  defp create_active_agent_tab(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state) do
    rows = max(state.frontend.terminal_viewport.rows, 1)
    cols = max(state.frontend.terminal_viewport.cols, 1)
    windows = agent_tab_windows(rows, cols)
    context = EditorState.build_agent_tab_defaults(state, windows)
    {tb, tab} = TabBar.insert(tb, :agent, "Agent")
    tb = TabBar.update_context(tb, tab.id, context)

    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.set_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          tb
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
    |> EditorState.switch_tab(tab.id)
  end

  defp create_active_agent_tab(state), do: state

  @spec agent_tab_windows(pos_integer(), pos_integer()) :: Windows.t()
  defp agent_tab_windows(rows, cols) do
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, rows, cols)

    %Windows{
      tree: WindowTree.new(win_id),
      map: %{win_id => agent_window},
      active: win_id,
      next_id: win_id + 1
    }
  end

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

  @doc "Cycles to the next model in the configured rotation."
  @spec cycle_model(state()) :: state()
  def cycle_model(state) do
    if Runtime.active_session(state.shell_runtime) == nil do
      NoticeWorkflow.publish(state, "No agent session")
    else
      case Session.cycle_model(Runtime.active_session(state.shell_runtime)) do
        {:ok, %{"model" => model, "index" => index, "total" => total} = result} ->
          state = apply_model_and_provider(state, model)
          state = maybe_update_thinking_level(state, Map.get(result, "thinking_level"))

          Session.add_system_message(
            Runtime.active_session(state.shell_runtime),
            "Model: #{model} [#{index}/#{total}]"
          )

          NoticeWorkflow.publish(
            state,
            "Model: #{model} [#{index}/#{total}]"
          )

        {:error, reason} when is_binary(reason) ->
          NoticeWorkflow.publish(state, reason)

        {:error, reason} ->
          NoticeWorkflow.publish(state, "Error: #{inspect(reason)}")
      end
    end
  end

  @spec maybe_update_thinking_level(state(), term()) :: state()
  @spec apply_model_and_provider(state(), String.t()) :: state()
  defp apply_model_and_provider(state, model) do
    provider = AgentConfig.extract_provider_prefix(model)

    state
    |> update_agent_ui(&UIState.set_model_name(&1, model))
    |> update_agent_ui(&UIState.set_provider_name(&1, provider))
  end

  defp maybe_update_thinking_level(state, level) when is_binary(level) do
    update_agent_ui(state, &UIState.set_thinking_level(&1, level))
  end

  defp maybe_update_thinking_level(state, _level), do: state

  @doc "Sets the agent model without resetting conversation context."
  @spec set_model(state(), String.t()) :: state()
  def set_model(state, model) do
    state = apply_model_and_provider(state, model)

    case Runtime.active_session(state.shell_runtime) do
      nil ->
        NoticeWorkflow.publish(state, "Model: #{model}")

      session ->
        case Session.set_model(session, model) do
          :ok ->
            Session.add_system_message(session, "Model: #{model}")
            NoticeWorkflow.publish(state, "Model: #{model}")

          {:error, reason} when is_binary(reason) ->
            NoticeWorkflow.publish(state, reason)

          {:error, reason} ->
            NoticeWorkflow.publish(
              state,
              "Error: #{inspect(reason)}"
            )
        end
    end
  end

  # ── Scope commands (keymap scope dispatch) ──────────────────────────────────
  #
  # These commands are bound in Keymap.Scope.Agent and dispatched through the
  # scope resolution system. Focus-aware commands check state.workspace.agent_ui.focus to
  # route to the correct panel (chat vs file viewer).

  # ── Fold / Collapse ────────────────────────────────────────────────────────

  @doc "Toggles collapse at cursor (currently toggles all)."
  @spec scope_toggle_collapse(state()) :: state()
  def scope_toggle_collapse(state), do: toggle_all_collapses(state)

  @doc "Toggles ALL collapses."
  @spec scope_toggle_all_collapse(state()) :: state()
  def scope_toggle_all_collapse(state), do: toggle_all_collapses(state)

  @doc "Expands at cursor (stubbed, toggles all for now)."
  @spec scope_expand_at_cursor(state()) :: state()
  def scope_expand_at_cursor(state), do: state

  @doc "Collapses at cursor (stubbed, toggles all for now)."
  @spec scope_collapse_at_cursor(state()) :: state()
  def scope_collapse_at_cursor(state), do: state

  @doc "Collapses all thinking/tool blocks."
  @spec scope_collapse_all(state()) :: state()
  def scope_collapse_all(state), do: toggle_all_collapses(state)

  @doc "Expands all thinking/tool blocks."
  @spec scope_expand_all(state()) :: state()
  def scope_expand_all(state), do: toggle_all_collapses(state)

  # ── Bracket navigation ────────────────────────────────────────────────────

  @doc "Jumps to next message (stubbed)."
  @spec scope_next_message(state()) :: state()
  def scope_next_message(state), do: state

  @doc "Jumps to next code block or diff hunk."
  @spec scope_next_code_block(state()) :: state()
  def scope_next_code_block(state) do
    case state.workspace.agent_ui.view.preview do
      %Preview{content: {:diff, review}} ->
        update_preview(state, &Preview.update_diff(&1, fn _ -> DiffReview.next_hunk(review) end))

      _ ->
        state
    end
  end

  @doc "Jumps to next tool call (stubbed)."
  @spec scope_next_tool_call(state()) :: state()
  def scope_next_tool_call(state), do: state

  @doc "Jumps to previous message (stubbed)."
  @spec scope_prev_message(state()) :: state()
  def scope_prev_message(state), do: state

  @doc "Jumps to previous code block or diff hunk."
  @spec scope_prev_code_block(state()) :: state()
  def scope_prev_code_block(state) do
    case state.workspace.agent_ui.view.preview do
      %Preview{content: {:diff, review}} ->
        update_preview(state, &Preview.update_diff(&1, fn _ -> DiffReview.prev_hunk(review) end))

      _ ->
        state
    end
  end

  @doc "Jumps to previous tool call (stubbed)."
  @spec scope_prev_tool_call(state()) :: state()
  def scope_prev_tool_call(state), do: state

  # ── Copy ───────────────────────────────────────────────────────────────────

  @doc "Copies the code block at the cursor to the clipboard."
  @spec scope_copy_code_block(state()) :: state()
  def scope_copy_code_block(state) do
    case scroll_context(state) do
      nil ->
        state

      {_idx, msg, line_type} ->
        text = Message.text(msg)

        if line_type == :code do
          blocks = Markdown.extract_code_blocks(text)
          content = code_block_for_scroll(state, blocks)
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
      {_idx, msg, _type} -> copy_to_clipboard(state, Message.text(msg), "message")
    end
  end

  # ── Open code block ────────────────────────────────────────────────────────

  @doc "Opens the code block at the cursor in an editor buffer."
  @spec scope_open_code_block(state()) :: state()
  def scope_open_code_block(state) do
    case scroll_context(state) do
      nil ->
        state

      {_idx, msg, :code} ->
        text = Message.text(msg)
        blocks = Markdown.extract_code_blocks(text)
        block = code_block_at_scroll(state, blocks)

        if block,
          do: AgentSession.open_code_block(state, block.language, block.content),
          else: state

      {_idx, _msg, _other_type} ->
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

      {_idx, msg, :code} ->
        text = Message.text(msg)
        blocks = Markdown.extract_code_blocks(text)
        block_index = code_block_index_for_scroll(state, blocks)
        block = Enum.at(blocks, block_index)

        if block do
          apply_code_block(state, text, block, block_index)
        else
          state
        end

      {_idx, _msg, _other_type} ->
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
        state = update_preview(state, &Preview.set_diff(&1, review))
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
         {msg_idx, _msg, _line_type} <- scroll_context(state),
         {id, msg} <- display_pair_at(state, session, msg_idx),
         false <- synthetic_display_message?(msg) do
      Session.toggle_pin(session, id)
    end

    state
  catch
    :exit, _ -> state
  end

  @spec display_pair_at(state(), pid(), non_neg_integer()) :: {pos_integer(), Message.t()} | nil
  defp display_pair_at(state, session, msg_idx) do
    pairs =
      case state.workspace.agent_ui.panel.cached_display_message_pairs do
        [] -> Session.messages_with_ids(session)
        cached -> cached
      end

    Enum.at(pairs, msg_idx)
  end

  @spec synthetic_display_message?(term()) :: boolean()
  defp synthetic_display_message?({:system, "── pinned ──", :info}), do: true
  defp synthetic_display_message?({:system, "── " <> _rest, :info}), do: true
  defp synthetic_display_message?(_msg), do: false

  # ── Input focus ────────────────────────────────────────────────────────────

  @doc "Focuses the input field and transitions to insert mode."
  @spec scope_focus_input(state()) :: state()
  def scope_focus_input(state) do
    state = update_agent_ui(state, &PromptBuffer.set_input_focused(&1, true))
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

  @doc "Switches focus between chat and file viewer panels."
  @spec scope_switch_focus(state()) :: state()
  def scope_switch_focus(state) do
    if state.workspace.agent_ui.view |> UIState.View.focus() == :chat do
      update_agent_ui(state, &UIState.set_focus(&1, :file_viewer))
    else
      update_agent_ui(state, &UIState.set_focus(&1, :chat))
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
    PickerUI.open(state, MingaEditor.UI.Picker.AgentSessionSource)
  end

  # ── Help ───────────────────────────────────────────────────────────────────

  @doc "Toggles the help overlay."
  @spec scope_toggle_help(state()) :: state()
  def scope_toggle_help(state), do: update_agent_ui(state, &UIState.toggle_help/1)

  # ── Close / dismiss ────────────────────────────────────────────────────────

  @doc "Returns from the agent view to the recorded editor context."
  @spec scope_close(state()) :: state()
  def scope_close(state), do: return_to_editor(state)

  @doc """
  Returns to the source line a provenance jump came from.

  Closes the loop for "jump from code into the agent": leaves the agent view,
  reopens the origin file, and places the cursor on the line the user pressed
  `SPC g w` on. No-op with a status message when there is no active jump.
  """
  @spec scope_provenance_return(state()) :: state()
  def scope_provenance_return(state) do
    case state.workspace.agent_ui.panel.provenance_jump do
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

  # Search input handling delegated to AgentSubStates.

  @spec handle_search_key(state(), non_neg_integer()) :: state()
  def handle_search_key(state, cp), do: AgentSubStates.handle_search_key(state, cp)

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
  defp safe_recall_queues(session) do
    Session.recall_queues(session)
  catch
    :exit, _ -> {[], []}
  end

  @spec restore_queued_to_prompt(state(), [String.t() | [ReqLLM.Message.ContentPart.t()]]) ::
          state()
  defp restore_queued_to_prompt(state, []), do: state

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

  @spec toggle_all_collapses(state()) :: state()
  defp toggle_all_collapses(state) do
    if Runtime.active_session(state.shell_runtime) do
      Session.toggle_all_tool_collapses(Runtime.active_session(state.shell_runtime))
    end

    state
  end

  @spec scroll_context(state()) ::
          {non_neg_integer(), Message.t(), Transcript.line_type()} | nil
  defp scroll_context(state) do
    session = Runtime.active_session(state.shell_runtime)
    panel = state.workspace.agent_ui.panel

    if session do
      messages = safe_messages(session)
      line_map = cached_or_compute_line_index(panel, messages)

      display_msgs =
        case panel.cached_display_messages do
          [] -> messages
          cached -> cached
        end

      total = Enum.count(line_map)
      target = Minga.Editing.resolve_scroll(panel.scroll, total, 1)

      case Enum.at(line_map, target) do
        {msg_idx, line_type} -> {msg_idx, Enum.at(display_msgs, msg_idx), line_type}
        nil -> nil
      end
    else
      nil
    end
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

  @spec code_block_for_scroll(state(), [Markdown.code_block()]) :: String.t()
  defp code_block_for_scroll(_state, []), do: ""

  defp code_block_for_scroll(state, blocks) do
    idx = code_block_index_for_scroll(state, blocks)
    Enum.at(blocks, idx, hd(blocks)).content
  end

  @spec code_block_at_scroll(state(), [Markdown.code_block()]) :: Markdown.code_block() | nil
  defp code_block_at_scroll(_state, []), do: nil

  defp code_block_at_scroll(state, blocks) do
    index = code_block_index_for_scroll(state, blocks)
    Enum.at(blocks, index)
  end

  @spec code_block_index_for_scroll(state(), [Markdown.code_block()]) :: non_neg_integer()
  defp code_block_index_for_scroll(state, blocks) do
    session = Runtime.active_session(state.shell_runtime)
    panel = state.workspace.agent_ui.panel
    messages = safe_messages(session)

    line_map = cached_or_compute_line_index(panel, messages)

    total = Enum.count(line_map)
    target = Minga.Editing.resolve_scroll(panel.scroll, total, 1)

    {msg_idx, _type} =
      case Enum.at(line_map, target) do
        nil -> {0, :text}
        entry -> entry
      end

    msg_start =
      Enum.find_index(line_map, fn {idx, _} -> idx == msg_idx end) || 0

    lines_for_msg =
      line_map
      |> Enum.drop(msg_start)
      |> Enum.take_while(fn {idx, _} -> idx == msg_idx end)

    relative = target - msg_start
    idx = count_code_block_at(lines_for_msg, relative)
    min(idx, Enum.count(blocks) - 1)
  end

  @spec count_code_block_at(
          [{non_neg_integer(), Transcript.line_type()}],
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp count_code_block_at(lines, target_offset) do
    lines
    |> Enum.take(target_offset + 1)
    |> Enum.reduce({0, false}, fn {_idx, type}, {block_count, in_code} ->
      case {type, in_code} do
        {:code, false} -> {block_count, true}
        {:code, true} -> {block_count, true}
        {_, true} -> {block_count + 1, false}
        {_, false} -> {block_count, false}
      end
    end)
    |> elem(0)
  end

  @spec safe_messages(pid()) :: [Message.t()]
  defp safe_messages(session) do
    Session.messages(session)
  catch
    :exit, _ -> []
  end

  # Returns the cached line index from the panel state if available,
  # otherwise recomputes from messages. The cache is populated by
  # AgentLifecycle.sync_transcript/1 on every message update.
  @spec cached_or_compute_line_index(Panel.t(), [Message.t()]) ::
          [{non_neg_integer(), Transcript.line_type()}]
  defp cached_or_compute_line_index(panel, messages) do
    case panel.cached_line_index do
      [] -> Transcript.line_message_index(messages)
      cached -> cached
    end
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
    {:agent_cycle_model, "Cycle AI agent model", :cycle_model},
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
    {:agent_ctrl_c, "Abort (streaming) or normal mode (idle)", :scope_ctrl_c},
    {:agent_queue_follow_up, "Queue as follow-up or submit if idle", :scope_queue_follow_up},
    {:agent_dequeue, "Dequeue messages back to editor", :scope_dequeue},
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
    {:agent_toggle_collapse, "Toggle collapse at cursor", :scope_toggle_collapse},
    {:agent_toggle_all_collapse, "Toggle collapse all", :scope_toggle_all_collapse},
    {:agent_expand_at_cursor, "Expand at cursor", :scope_expand_at_cursor},
    {:agent_collapse_at_cursor, "Collapse at cursor", :scope_collapse_at_cursor},
    {:agent_collapse_all, "Collapse all", :scope_collapse_all},
    {:agent_expand_all, "Expand all", :scope_expand_all},
    {:agent_next_message, "Next message", :scope_next_message},
    {:agent_next_code_block, "Next code block", :scope_next_code_block},
    {:agent_next_tool_call, "Next tool call", :scope_next_tool_call},
    {:agent_prev_message, "Previous message", :scope_prev_message},
    {:agent_prev_code_block, "Previous code block", :scope_prev_code_block},
    {:agent_prev_tool_call, "Previous tool call", :scope_prev_tool_call},
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
    {:agent_toggle_help, "Toggle agent help", :scope_toggle_help},
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
        execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.AgentModelSource) end
      },
      %Minga.Command{
        name: :agent_pick_thinking,
        description: "Pick AI thinking level",
        requires_buffer: false,
        execute: &pick_thinking_level/1
      },
      %Minga.Command{
        name: :agent_session_history,
        description: "Resume agent session",
        requires_buffer: false,
        execute: fn state ->
          PickerUI.open(state, MingaEditor.UI.Picker.AgentSessionSource, %{persisted_only: true})
        end
      }
    ]

    dispatched ++ pickers
  end
end
