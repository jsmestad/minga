defmodule MingaEditor.AgentLifecycle do
  @moduledoc """
  Agent session lifecycle helpers for the Editor GenServer.

  Handles agent session startup, auto-context loading, semantic transcript
  caching, and tab label updates. These are called by the
  Editor during init, file open, and surface effect processing.

  These orchestration workflows start or query session and prompt processes, then install state through its owners.
  """

  alias MingaAgent.Checklist
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.ConnectionAction
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.MarkdownHighlight
  alias MingaEditor.Agent.ProvenanceJump
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Session, as: AgentSession
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.Session.Transcript.{Changes, Cursor, Snapshot}
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias Minga.Buffer
  alias Minga.Config
  alias MingaEditor.Commands
  alias MingaEditor.LayoutPreset
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.TabWorkflow
  alias MingaEditor.WorkspaceWorkflow
  @type state :: EditorState.t()

  # Maximum characters of tool call result to send for styled rendering.
  # Matches the truncation in Transcript.message_to_markdown/1.
  @max_styled_result_chars 500

  @doc "Rebuilds the active agent presentation from its authoritative session snapshot."
  @spec rebuild_agent_from_session(state(), Tab.t() | pid()) :: state()
  def rebuild_agent_from_session(
        state,
        %Tab{kind: :agent, payload: %Agent{connection_status: status}}
      )
      when status in [:disconnected, :unavailable],
      do: install_unavailable_chat(state)

  def rebuild_agent_from_session(state, %Tab{kind: :agent, payload: %Agent{session: session_pid}})
      when is_pid(session_pid), do: rebuild_agent_from_session(state, session_pid)

  def rebuild_agent_from_session(state, session_pid) when is_pid(session_pid) do
    case safe_editor_snapshot(session_pid) do
      nil ->
        install_unavailable_chat(state)

      snapshot ->
        apply_session_snapshot(state, session_pid, snapshot)
    end
  end

  def rebuild_agent_from_session(state, %Tab{kind: :agent}),
    do: MingaEditor.Shell.Traditional.Workflow.install_agent_cache_reset(state)

  def rebuild_agent_from_session(state, %Tab{}), do: state

  @spec install_unavailable_chat(state()) :: state()
  defp install_unavailable_chat(state) do
    state
    |> MingaEditor.Shell.Traditional.Workflow.install_agent_cache_reset()
    |> MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
      UIState.transition_chat(state.workspace.agent_ui, :unavailable)
    )
  end

  @doc "Hydrates execution and resolved model facts without replaying activation effects."
  @spec apply_session_snapshot(state(), pid(), AgentSession.editor_snapshot()) :: state()
  def apply_session_snapshot(state, session_pid, snapshot) when is_pid(session_pid) do
    agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

    agent =
      agent
      |> AgentState.apply_session_snapshot(
        session_pid,
        Map.get(snapshot, :status, :idle),
        Map.get(snapshot, :pending_approval),
        Map.get(snapshot, :error),
        Map.get(snapshot, :active_tool_name)
      )
      |> AgentState.project_question(session_pid, Map.get(snapshot, :pending_question))
      |> AgentState.project_queue_target(session_pid, Map.get(snapshot, :queue_target))
      |> AgentState.project_stop_target(session_pid, Map.get(snapshot, :stop_target))

    ui = state.workspace.agent_ui

    panel =
      Panel.set_credential_readiness(
        ui.panel,
        Map.get(snapshot, :credential_readiness, ui.panel.credential_readiness)
      )

    ui =
      ui
      |> UIState.replace_panel(panel)
      |> UIState.project_model_selection(Map.get(snapshot, :model_selection))
      |> UIState.replace_activity(
        Activity.restore_running_tools(ui.view.activity, Map.get(snapshot, :active_tools, []))
      )

    ui =
      case Map.get(snapshot, :connection) do
        %ConnectionSnapshot{target: %{session: ^session_pid}} = connection ->
          ui
          |> UIState.project_connection(connection)
          |> UIState.report_chat_start_failure(Map.get(snapshot, :error))

        _unavailable ->
          ui
          |> UIState.clear_connection()
          |> UIState.transition_chat({:conversation, session_pid})
      end

    state
    |> MingaEditor.Shell.Traditional.Workflow.install_agent_state(agent)
    |> MingaEditor.Shell.Traditional.Workflow.install_agent_ui(project_checklist(ui, snapshot))
  end

  @spec project_checklist(UIState.t(), AgentSession.editor_snapshot()) :: UIState.t()
  defp project_checklist(ui, %{checklist: checklist}) do
    {_revision, todos} = Checklist.snapshot(checklist)
    UIState.replace_activity(ui, Activity.set_todos(ui.view.activity, todos))
  end

  defp project_checklist(ui, _legacy_snapshot), do: ui

  @spec safe_editor_snapshot(pid()) :: map() | nil
  defp safe_editor_snapshot(session_pid) do
    AgentSession.editor_snapshot(session_pid)
  catch
    :exit, _ -> nil
  end

  @doc """
  Starts the agent session and prepares its prompt when the agent pane is visible during init.

  Also loads auto-context if configured. Called once the port is ready.
  """
  @spec maybe_start_session(state()) :: state()
  def maybe_start_session(state) do
    if LayoutPreset.has_agent_chat?(state) do
      case Runtime.active_tab(state.shell_runtime) do
        %Tab{kind: :agent, id: id} ->
          state |> TabWorkflow.switch(id) |> start_session_if_needed()

        _tab ->
          start_session_if_needed(state)
      end
    else
      state
    end
  rescue
    e ->
      Minga.Log.warning(:agent, "Failed to start agent session at boot: #{Exception.message(e)}")
      state
  end

  @spec start_session_if_needed(state()) :: state()
  defp start_session_if_needed(state) do
    case MingaEditor.Shell.Runtime.active_session(state.shell_runtime) do
      nil ->
        state = Commands.Agent.ensure_agent_session(state)
        maybe_load_auto_context(state, Minga.CLI.startup_flags())

      _session ->
        state
    end
  end

  @doc """
  Sets a file's content as the agentic preview pane if the agent pane
  is active and the preview is empty. Called when a file is opened while
  the agent view is already active.
  """
  @spec maybe_set_auto_context(state(), String.t(), pid()) :: state()
  def maybe_set_auto_context(state, file_path, buffer_pid) do
    cli_flags = Minga.CLI.startup_flags()
    auto_context = Config.get(:agent_auto_context)
    agent_visible = LayoutPreset.has_agent_chat?(state)
    preview_empty = state.workspace.agent_ui.view.preview.content == :empty

    if agent_visible and preview_empty and auto_context and not cli_flags.no_context do
      content = Buffer.content(buffer_pid)
      update_preview(state, &Preview.set_file(&1, file_path, content))
    else
      state
    end
  end

  @doc """
  Caches the semantic agent transcript metadata for the current session messages.

  Called as a surface effect when the agent view receives new messages.
  """
  @spec sync_transcript(state()) :: state()
  def sync_transcript(state), do: sync_transcript(state, :refresh)

  @doc "Refreshes the transcript for a render or a committed message change."
  @spec sync_transcript(state(), :refresh | :messages_changed) :: state()
  def sync_transcript(state, trigger) do
    session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)

    sync_session_transcript(state, session, trigger)
  end

  @spec sync_session_transcript(state(), pid() | nil, :refresh | :messages_changed) :: state()
  defp sync_session_transcript(state, session, _trigger)
       when is_pid(session) and node(session) == node() do
    projection = state.workspace.agent_ui.panel.transcript

    case AgentSession.transcript_since(session, projection.source_cursor || :snapshot) do
      {:unchanged, cursor} ->
        reuse_transcript(state, projection, cursor)

      {:changes, %Changes{entries: [], pins_changed?: false, cursor: cursor}} ->
        reuse_transcript(state, projection, cursor)

      {:changes, %Changes{entries: entries}} ->
        {:snapshot, snapshot} = AgentSession.transcript_since(session, :snapshot)
        install_transcript_snapshot(state, snapshot, :changed, length(entries))

      {:snapshot, snapshot} ->
        state
        |> recover_changed_files(session)
        |> install_transcript_snapshot(snapshot, :changed, 0)

      {:reset, _reason, snapshot} ->
        state
        |> recover_changed_files(session)
        |> install_transcript_snapshot(snapshot, :reset, 0)

      {:error, :invalid_cursor} ->
        Minga.Log.warning(
          :agent,
          "Agent transcript cursor was invalid; reading an atomic snapshot."
        )

        {:snapshot, snapshot} = AgentSession.transcript_since(session, :snapshot)
        install_transcript_snapshot(state, snapshot, :reset, 0)
    end
  catch
    :exit, _ -> state
  end

  defp sync_session_transcript(state, session, trigger) when is_pid(session) do
    case {safe_session_messages(session), trigger} do
      {{:ok, messages}, :messages_changed} ->
        state
        |> cache_transcript(messages)
        |> apply_transcript_names(messages)

      {{:ok, messages}, :refresh} ->
        cache_transcript(state, messages)

      {:dead_session, _trigger} ->
        state
    end
  end

  defp sync_session_transcript(state, nil, _trigger), do: state

  @spec recover_changed_files(state(), pid()) :: state()
  defp recover_changed_files(state, session) do
    with {:ok, _tab, %{target: %ConnectionTarget{session: ^session} = target}} <-
           ConnectionAction.origin(state),
         {:ok, files} <- AgentSession.changed_file_counts(target) do
      ui = state.workspace.agent_ui
      timeline = EditTimeline.recover_files(ui.view.edit_timeline, files)
      ui = UIState.replace_edit_timeline(ui, timeline)
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)
    else
      _unavailable -> state
    end
  end

  @spec install_transcript_snapshot(state(), Snapshot.t(), :changed | :reset, non_neg_integer()) ::
          state()
  defp install_transcript_snapshot(state, snapshot, outcome, previously_read) do
    {messages, pairs} =
      Enum.map_reduce(snapshot.entries, [], fn %{id: id, message: message}, pairs ->
        {message, [{id, message} | pairs]}
      end)

    opts =
      [message_ids: Enum.reverse(pairs), source_cursor: snapshot.cursor]
      |> maybe_put_pinned_ids(snapshot.pinned_ids)

    {empty_state, first_run} =
      if Transcript.first_run_transcript?(messages) do
        empty_state = empty_state_for_panel(state.workspace.agent_ui.panel, nil)
        {empty_state, {messages, Keyword.delete(opts, :source_cursor), empty_state}}
      else
        {nil, nil}
      end

    synced =
      cache_display_transcript(
        state,
        messages,
        empty_state,
        Keyword.put(opts, :first_run, first_run)
      )

    synced
    |> apply_transcript_names(messages)
    |> report_transcript_sync(outcome, previously_read + snapshot.count)
  end

  @spec reuse_transcript(state(), TranscriptProjection.t(), Cursor.t()) :: state()
  defp reuse_transcript(state, projection, cursor) do
    case refresh_first_run(state, projection.first_run, cursor) do
      {:rebuilt, synced} ->
        report_transcript_sync(synced, :unchanged, 0)

      :unchanged ->
        state
        |> maybe_restyle_retained_transcript(projection)
        |> advance_transcript_cursor(cursor)
        |> report_transcript_sync(:unchanged, 0)
    end
  end

  @spec refresh_first_run(state(), TranscriptProjection.first_run() | nil, Cursor.t()) ::
          :unchanged | {:rebuilt, state()}
  defp refresh_first_run(_state, nil, _cursor), do: :unchanged

  defp refresh_first_run(state, {messages, opts, previous}, cursor) do
    case empty_state_for_panel(state.workspace.agent_ui.panel, nil) do
      ^previous ->
        :unchanged

      empty_state ->
        opts = [source_cursor: cursor, first_run: {messages, opts, empty_state}] ++ opts
        {:rebuilt, cache_display_transcript(state, messages, empty_state, opts)}
    end
  end

  @spec maybe_restyle_retained_transcript(state(), TranscriptProjection.t()) :: state()
  defp maybe_restyle_retained_transcript(state, %TranscriptProjection{messages: []}), do: state

  defp maybe_restyle_retained_transcript(state, projection) do
    fingerprint = TranscriptProjection.styled_cache_fingerprint(state.appearance.theme.syntax)

    case TranscriptProjection.styled_for(projection, fingerprint) do
      :stale ->
        ids = Enum.map(projection.message_pairs, fn {id, _message} -> id end)
        styled = compute_styled_messages(state, projection.messages, ids, [], [])
        panel = Panel.cache_styled_messages(state.workspace.agent_ui.panel, styled, fingerprint)
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(state, panel)

      {:ok, _styled} ->
        state
    end
  end

  @spec advance_transcript_cursor(state(), Cursor.t()) :: state()
  defp advance_transcript_cursor(
         %{workspace: %{agent_ui: %{panel: %{transcript: %{source_cursor: cursor}}}}} = state,
         cursor
       ),
       do: state

  defp advance_transcript_cursor(state, cursor) do
    panel = state.workspace.agent_ui.panel

    MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
      state,
      Panel.advance_transcript_cursor(panel, cursor)
    )
  end

  @spec report_transcript_sync(state(), :unchanged | :changed | :reset, non_neg_integer()) ::
          state()
  defp report_transcript_sync(state, outcome, entries_read) do
    Minga.Telemetry.execute([:minga, :agent, :transcript_sync], %{entries_read: entries_read}, %{
      outcome: outcome
    })

    state
  end

  @doc "Caches semantic transcript metadata for an explicit message list."
  @spec cache_messages(state(), [term()]) :: state()
  def cache_messages(state, []), do: clear_transcript_cache(state)

  def cache_messages(state, messages) when is_list(messages) do
    cache_transcript(state, messages)
  end

  @spec safe_session_messages(pid()) :: {:ok, [term()]} | :dead_session
  defp safe_session_messages(session) do
    {:ok, AgentSession.messages(session)}
  catch
    :exit, _ -> :dead_session
  end

  @spec cache_transcript(state(), [term()]) :: state()
  defp cache_transcript(state, []) do
    cache_empty_transcript(state, first_run_empty_state(state, []))
  end

  defp cache_transcript(state, messages) do
    cache_display_transcript(state, messages, first_run_empty_state(state, messages))
  end

  @spec cache_display_transcript(state(), [term()], Transcript.empty_state(), keyword() | nil) ::
          state()
  defp cache_display_transcript(state, messages, empty_state, opts \\ nil) do
    panel = state.workspace.agent_ui.panel
    projection = panel.transcript
    jump = projection.provenance_jump

    sync_opts =
      opts ||
        add_session_display_opts(
          [],
          MingaEditor.Shell.Runtime.active_session(state.shell_runtime)
        )

    sync_opts = maybe_put_empty_state(sync_opts, empty_state)

    # A pending provenance jump may reveal an older, paged-out turn so it can be landed on.
    # Otherwise keep the current display window.
    display_start = jump_display_start(jump, projection.display_start, sync_opts[:message_ids])

    sync_opts =
      if display_start > 0,
        do: Keyword.put(sync_opts, :display_start_index, display_start),
        else: sync_opts

    result = Transcript.display(messages, sync_opts)

    # Compute styled runs for GUI rendering against the displayed transcript.
    # Reuse unchanged entries only when the style context still matches the cached fingerprint.
    styled_fingerprint =
      TranscriptProjection.styled_cache_fingerprint(state.appearance.theme.syntax)

    {previous_messages, previous_styled} =
      case TranscriptProjection.styled_for(projection, styled_fingerprint) do
        :stale -> {[], []}
        {:ok, styled} -> {projection.messages, styled || []}
      end

    message_ids = Enum.map(result.display_message_pairs, fn {id, _message} -> id end)

    styled =
      compute_styled_messages(
        state,
        result.display_messages,
        message_ids,
        previous_messages,
        previous_styled
      )

    styled_assistant_count =
      Enum.count(styled, fn
        nil -> false
        _ -> true
      end)

    Minga.Log.debug(
      :agent,
      "[sync] styled cache: #{Enum.count(styled)} entries, #{styled_assistant_count} with content (#{Enum.count(messages)} messages)"
    )

    # Cache the line index and styled messages in the UI state so
    # callers can read them without recomputing. Persist the (possibly lowered)
    # display window and mark the jump landed so later re-syncs hold position
    # instead of re-pinning to the bottom.
    MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
      state,
      (fn p ->
         Panel.cache_transcript_display(p, result, styled,
           display_start: display_start,
           provenance_jump: advance_jump(jump),
           styled_fingerprint: styled_fingerprint,
           source_cursor: sync_opts[:source_cursor],
           first_run: sync_opts[:first_run],
           turn_count: MingaAgent.SessionMetadata.turn_count(messages)
         )
       end).(state.workspace.agent_ui.panel)
    )
  end

  @spec cache_empty_transcript(state(), Transcript.empty_state()) :: state()
  defp cache_empty_transcript(state, nil), do: clear_transcript_cache(state)

  defp cache_empty_transcript(state, empty_state) do
    cache_display_transcript(state, [], empty_state)
  end

  @spec clear_transcript_cache(state()) :: state()
  defp clear_transcript_cache(state) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
      state,
      (&Panel.clear_transcript_cache/1).(state.workspace.agent_ui.panel)
    )
  end

  @spec first_run_empty_state(state(), [term()]) :: Transcript.empty_state()
  defp first_run_empty_state(state, messages) do
    if Transcript.first_run_transcript?(messages) do
      panel = state.workspace.agent_ui.panel
      empty_state_for_panel(panel, MingaEditor.Shell.Runtime.active_session(state.shell_runtime))
    end
  end

  @spec empty_state_for_panel(MingaEditor.Agent.UIState.Panel.t(), pid() | nil) ::
          Transcript.empty_state()
  defp empty_state_for_panel(%Panel{credential_readiness: :checking}, _session), do: :checking

  defp empty_state_for_panel(panel, session) do
    empty_state_for_status(
      configured_model?(panel.model_name),
      credentials_configured?(panel, session)
    )
  end

  @spec empty_state_for_status(boolean(), boolean()) :: Transcript.empty_state()
  defp empty_state_for_status(false, _credentials_configured), do: :no_model
  defp empty_state_for_status(true, false), do: :credentials_missing
  defp empty_state_for_status(true, true), do: nil

  @spec maybe_put_empty_state(keyword(), Transcript.empty_state()) :: keyword()
  defp maybe_put_empty_state(opts, nil), do: opts
  defp maybe_put_empty_state(opts, empty_state), do: Keyword.put(opts, :empty_state, empty_state)

  @spec configured_model?(String.t()) :: boolean()
  defp configured_model?(model) when model in ["", "unknown"], do: false
  defp configured_model?(model), do: model != AgentConfig.unconfigured_model()

  @spec credentials_configured?(MingaEditor.Agent.UIState.Panel.t(), pid() | nil) :: boolean()
  defp credentials_configured?(_panel, session) when is_pid(session) do
    session
    |> AgentSession.editor_snapshot()
    |> Map.get(:credentials_configured, false)
  catch
    :exit, _ -> false
  end

  defp credentials_configured?(panel, _session), do: panel.credentials_configured

  # The display window needed to render the jump target. Reveals a paged-out
  # target turn; otherwise keeps the panel's current window.
  @spec jump_display_start(
          ProvenanceJump.t() | nil,
          non_neg_integer(),
          [{pos_integer(), term()}] | nil
        ) ::
          non_neg_integer()
  defp jump_display_start(nil, current, _pairs), do: current
  defp jump_display_start(%ProvenanceJump{landed?: true}, current, _pairs), do: current

  defp jump_display_start(%ProvenanceJump{target_message_id: id}, current, pairs) do
    case pairs && Enum.find_index(pairs, fn {mid, _msg} -> mid == id end) do
      nil -> current
      target_index -> min(current, target_index)
    end
  end

  # After the first sync that lands the jump, mark it landed so subsequent
  # syncs hold the cursor (`:keep`) rather than re-landing or re-pinning.
  @spec advance_jump(ProvenanceJump.t() | nil) :: ProvenanceJump.t() | nil
  defp advance_jump(nil), do: nil
  defp advance_jump(%ProvenanceJump{} = jump), do: ProvenanceJump.mark_landed(jump)

  @spec apply_transcript_names(state(), [term()]) :: state()
  defp apply_transcript_names(state, []), do: state

  defp apply_transcript_names(state, messages) do
    state
    |> maybe_rename_workspace_from_assistant(messages)
    |> maybe_update_tab_label(messages)
  end

  @spec maybe_rename_workspace_from_assistant(state(), [term()]) :: state()
  defp maybe_rename_workspace_from_assistant(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tab_bar}}} = state,
         messages
       ) do
    with session when is_pid(session) <- Runtime.active_session(state.shell_runtime),
         %Workspace{custom_name: nil, id: id} <-
           TabBar.find_workspace_by_session(tab_bar, session),
         text when is_binary(text) <- first_assistant_opening(messages) do
      WorkspaceWorkflow.install_auto_named_workspace(state, id, text)
    else
      _unavailable -> state
    end
  end

  defp maybe_rename_workspace_from_assistant(state, _messages), do: state

  @spec maybe_update_tab_label(state(), [term()]) :: state()
  defp maybe_update_tab_label(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{active_id: active_id} = tab_bar}}} = state,
         messages
       ) do
    with %Tab{kind: :agent, label: label} when is_binary(label) <- TabBar.active(tab_bar),
         true <- default_agent_label?(label),
         text when is_binary(text) <- first_user_message(messages) do
      tab_bar = TabBar.update_label(tab_bar, active_id, truncate_label(text, 30))

      shell =
        MingaEditor.Shell.Traditional.State.install_tab_bar(state.shell_runtime.state, tab_bar)

      %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell)}
    else
      _unavailable -> state
    end
  end

  defp maybe_update_tab_label(state, _messages), do: state

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec maybe_load_auto_context(state(), Minga.CLI.flags()) :: state()
  defp maybe_load_auto_context(state, %{no_context: true}), do: state

  defp maybe_load_auto_context(state, _flags) do
    auto_context = Config.get(:agent_auto_context)
    active_buf = state.workspace.buffers.active

    if auto_context and active_buf do
      load_buffer_as_preview(state, active_buf)
    else
      state
    end
  end

  @spec load_buffer_as_preview(state(), pid()) :: state()
  defp load_buffer_as_preview(state, buffer_pid) do
    case Buffer.file_path(buffer_pid) do
      nil ->
        state

      path ->
        content = Buffer.content(buffer_pid)
        update_preview(state, &Preview.set_file(&1, path, content))
    end
  end

  @spec update_preview(state(), (Preview.t() -> Preview.t())) :: state()
  defp update_preview(state, fun) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
      state,
      (fn ui ->
         UIState.replace_preview(ui, fun.(ui.view.preview))
       end).(state.workspace.agent_ui)
    )
  end

  @spec default_agent_label?(String.t()) :: boolean()
  defp default_agent_label?("Agent"), do: true
  defp default_agent_label?("New Agent"), do: true
  defp default_agent_label?("minga"), do: true
  defp default_agent_label?(_), do: false

  @spec first_user_message([term()]) :: String.t() | nil
  defp first_user_message(messages) do
    Enum.find_value(messages, fn
      {:user, text} -> text
      {:user, text, _attachments} -> text
      _ -> nil
    end)
  end

  @spec first_assistant_opening([term()]) :: String.t() | nil
  defp first_assistant_opening(messages) do
    Enum.find_value(messages, fn
      {:assistant, text} when is_binary(text) and text != "" ->
        text |> String.split("\n", parts: 2) |> hd() |> String.trim()

      _message ->
        nil
    end)
  end

  @spec truncate_label(String.t(), pos_integer()) :: String.t()
  defp truncate_label(text, max) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if String.length(line) > max do
      String.slice(line, 0, max - 1) <> "\u{2026}"
    else
      line
    end
  end

  # ── Styled message caching for GUI ─────────────────────────────────────────

  @doc """
  Re-computes cached styled messages for the semantic transcript.
  """
  @spec update_styled_cache(state()) :: state()
  def update_styled_cache(state) do
    session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)

    with true <- is_pid(session),
         messages when messages != [] <- displayed_messages_for_styling(state, session) do
      panel = state.workspace.agent_ui.panel

      styled_fingerprint =
        TranscriptProjection.styled_cache_fingerprint(state.appearance.theme.syntax)

      projection = panel.transcript

      {previous_messages, previous_styled} =
        case TranscriptProjection.styled_for(projection, styled_fingerprint) do
          :stale -> {[], []}
          {:ok, styled} -> {projection.messages, styled || []}
        end

      message_ids = displayed_message_ids_for_styling(state, session)

      styled =
        compute_styled_messages(
          state,
          messages,
          message_ids,
          previous_messages,
          previous_styled
        )

      MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
        state,
        (fn p ->
           Panel.cache_styled_messages(p, styled, styled_fingerprint)
         end).(state.workspace.agent_ui.panel)
      )
    else
      _ -> state
    end
  end

  @spec safe_messages(pid()) :: [term()]
  defp safe_messages(session) do
    AgentSession.messages(session)
  catch
    :exit, _ -> []
  end

  @spec displayed_messages_for_styling(state(), pid()) :: [term()]
  defp displayed_messages_for_styling(state, session) do
    case state.workspace.agent_ui.panel.transcript.messages do
      [] -> safe_messages(session)
      messages -> messages
    end
  end

  @spec displayed_message_ids_for_styling(state(), pid()) :: [pos_integer()]
  defp displayed_message_ids_for_styling(state, session) do
    panel = state.workspace.agent_ui.panel

    case panel.transcript.message_pairs do
      [] -> session |> AgentSession.messages_with_ids() |> Enum.map(fn {id, _message} -> id end)
      pairs -> Enum.map(pairs, fn {id, _message} -> id end)
    end
  catch
    :exit, _ -> []
  end

  # Cache one presentation for each displayed message. Nil slots preserve message order.
  @spec compute_styled_messages(
          state(),
          [term()],
          [pos_integer()],
          [term()],
          TranscriptProjection.styled_cache()
        ) ::
          TranscriptProjection.styled_cache()
  defp compute_styled_messages(state, messages, message_ids, previous_messages, previous_styled) do
    compute_styled_messages(
      messages,
      message_ids,
      previous_messages,
      previous_styled,
      0,
      state.appearance.theme.syntax,
      []
    )
  end

  @spec compute_styled_messages(
          [term()],
          [pos_integer()],
          [term()],
          TranscriptProjection.styled_cache(),
          non_neg_integer(),
          map(),
          [TranscriptProjection.rendered_message() | nil]
        ) :: [TranscriptProjection.rendered_message() | nil]
  defp compute_styled_messages(
         [],
         _message_ids,
         _previous_messages,
         _previous_styled,
         _idx,
         _theme_syntax,
         acc
       ) do
    Enum.reverse(acc)
  end

  defp compute_styled_messages(
         [message | messages],
         message_ids,
         previous_messages,
         previous_styled,
         idx,
         theme_syntax,
         acc
       ) do
    {next_previous_messages, next_previous_styled, cached} =
      cached_styled_message(message, previous_messages, previous_styled)

    {message_id, next_message_ids} = next_message_id(message_ids, idx)

    styled =
      case cached do
        {:ok, cached_styled} ->
          cached_styled

        :miss ->
          style_message(message, message_id, theme_syntax)
      end

    compute_styled_messages(
      messages,
      next_message_ids,
      next_previous_messages,
      next_previous_styled,
      idx + 1,
      theme_syntax,
      [styled | acc]
    )
  end

  @spec cached_styled_message(term(), [term()], TranscriptProjection.styled_cache()) ::
          {[term()], TranscriptProjection.styled_cache(),
           {:ok, TranscriptProjection.rendered_message() | nil} | :miss}
  defp cached_styled_message(message, [previous_message | previous_messages], [
         styled | previous_styled
       ])
       when message == previous_message do
    {previous_messages, previous_styled, {:ok, styled}}
  end

  defp cached_styled_message(_message, [_previous_message | previous_messages], [
         _styled | previous_styled
       ]) do
    {previous_messages, previous_styled, :miss}
  end

  defp cached_styled_message(_message, [_previous_message | previous_messages], []) do
    {previous_messages, [], :miss}
  end

  defp cached_styled_message(_message, [], [_styled | previous_styled]) do
    {[], previous_styled, :miss}
  end

  defp cached_styled_message(_message, [], []) do
    {[], [], :miss}
  end

  @spec next_message_id([pos_integer()], non_neg_integer()) :: {pos_integer(), [pos_integer()]}
  defp next_message_id([id | rest], _idx), do: {id, rest}
  defp next_message_id([], idx), do: {idx + 1, []}

  @spec style_message(term(), pos_integer(), map()) ::
          TranscriptProjection.rendered_message() | nil
  defp style_message({:assistant, text}, message_id, theme_syntax) do
    case MarkdownHighlight.render_blocks(text, nil, theme_syntax, message_id) do
      [] -> {:styled_lines, MarkdownHighlight.stylize(text, nil, theme_syntax)}
      [_ | _] = blocks -> {:markdown_blocks, blocks}
    end
  end

  defp style_message(
         {:tool_call, %MingaAgent.ToolCall{result: result}},
         _message_id,
         theme_syntax
       )
       when is_binary(result) and result != "" do
    text = String.slice(result, 0, @max_styled_result_chars)
    {:styled_lines, MarkdownHighlight.stylize(text, nil, theme_syntax)}
  end

  defp style_message(_message, _message_id, _theme_syntax), do: nil

  @spec add_session_display_opts(keyword(), pid() | nil) :: keyword()
  defp add_session_display_opts(opts, session) when is_pid(session) do
    pinned = AgentSession.pinned_ids(session)
    ids = AgentSession.messages_with_ids(session)

    opts
    |> Keyword.put(:message_ids, ids)
    |> maybe_put_pinned_ids(pinned)
  catch
    :exit, _ -> opts
  end

  defp add_session_display_opts(opts, _session), do: opts

  @spec maybe_put_pinned_ids(keyword(), MapSet.t(pos_integer())) :: keyword()
  defp maybe_put_pinned_ids(opts, pinned) do
    if MapSet.size(pinned) > 0 do
      Keyword.put(opts, :pinned_ids, pinned)
    else
      opts
    end
  end
end
