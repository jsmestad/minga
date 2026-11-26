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
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.MarkdownHighlight
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Session, as: AgentSession
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.Transcript.{Changes, Cursor, Entry, Snapshot}
  alias MingaAgent.TranscriptEntry
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
      |> AgentState.project_continue_target(session_pid, Map.get(snapshot, :continue_target))

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
          UIState.project_connection(ui, connection)

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
    Minga.Telemetry.span([:minga, :agent, :session_snapshot_read], %{}, fn ->
      read_editor_snapshot(session_pid)
    end)
  end

  @spec read_editor_snapshot(pid()) :: map() | nil
  defp read_editor_snapshot(session_pid) do
    # minga:allow-blocking — Editor, on Agent tab switch, open and draft reopen; the switch read kept by #3643
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
    case Runtime.active_session(state.shell_runtime) do
      nil ->
        state

      session ->
        if MingaEditor.Agent.Arrival.pending?(state, session),
          do: state,
          else: sync_session_transcript(state, session, trigger)
    end
  end

  # A local Session answers in the Editor's mailbox; the Editor never waits on it
  # (`MingaEditor.Agent.TranscriptSync`).
  @spec sync_session_transcript(state(), pid(), :refresh | :messages_changed) :: state()
  defp sync_session_transcript(state, session, _trigger)
       when is_pid(session) and node(session) == node(),
       do: MingaEditor.Agent.TranscriptSync.request(state, session)

  defp sync_session_transcript(state, session, trigger) when is_pid(session) do
    case {safe_session_messages(session), trigger} do
      {{:ok, messages}, :messages_changed} ->
        state
        |> refresh_remote_messages(messages, session)
        |> update_transcript_names()

      {{:ok, messages}, :refresh} ->
        refresh_remote_messages(state, messages, session)

      {:dead_session, _trigger} ->
        state
    end
  end

  @doc "Installs an ordered Session arrival without querying that Session again."
  @spec apply_editor_arrival(state(), pid(), AgentSession.editor_arrival()) :: state()
  def apply_editor_arrival(state, session, {snapshot, transcript}) do
    state
    |> apply_session_snapshot(session, snapshot)
    |> apply_arrival_transcript(transcript)
  end

  @doc "Installs one transcript read the active local Session answered (`MingaEditor.Agent.TranscriptSync`)."
  @spec install_transcript_reply(state(), AgentSession.editor_arrival_transcript()) :: state()
  def install_transcript_reply(state, transcript),
    do: apply_arrival_transcript(state, transcript, 1)

  @spec apply_arrival_transcript(state(), AgentSession.editor_arrival_transcript(), pos_integer()) ::
          state()
  defp apply_arrival_transcript(state, transcript, session_calls \\ 2)

  defp apply_arrival_transcript(state, {:unchanged, cursor}, session_calls) do
    reuse_transcript(state, cursor, session_calls)
  end

  defp apply_arrival_transcript(state, {:changes, changes}, session_calls) do
    install_transcript_changes(state, changes, session_calls)
  end

  defp apply_arrival_transcript(state, {:replace, outcome, snapshot, files}, session_calls) do
    state
    |> apply_changed_file_counts(files)
    |> install_transcript_snapshot(snapshot, outcome, session_calls)
  end

  @spec apply_changed_file_counts(state(), %{String.t() => pos_integer()} | nil) :: state()
  defp apply_changed_file_counts(state, nil), do: state

  defp apply_changed_file_counts(state, files) do
    ui = state.workspace.agent_ui
    timeline = EditTimeline.recover_files(ui.view.edit_timeline, files)
    ui = UIState.replace_edit_timeline(ui, timeline)
    MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)
  end

  @spec install_transcript_snapshot(state(), Snapshot.t(), :changed | :reset, pos_integer()) ::
          state()
  defp install_transcript_snapshot(state, snapshot, outcome, session_calls) do
    projection = state.workspace.agent_ui.panel.transcript

    projection =
      if outcome == :reset,
        do: TranscriptProjection.set_display_start(projection, 0),
        else: projection

    next =
      TranscriptProjection.replace(
        projection,
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        presentation_context(state)
      )

    state
    |> install_projection(next, :keep)
    |> update_transcript_names()
    |> report_transcript_sync(outcome, snapshot.count, session_calls)
  end

  @spec install_transcript_changes(state(), Changes.t(), pos_integer()) :: state()
  defp install_transcript_changes(state, changes, calls) do
    panel = state.workspace.agent_ui.panel

    reading =
      case panel.scroll do
        %{pinned: true} -> :follow
        %{offset: offset} -> offset
      end

    {projection, reading} =
      TranscriptProjection.apply_changes(
        panel.transcript,
        changes,
        reading,
        presentation_context(state)
      )

    state
    |> install_projection(projection, reading)
    |> update_transcript_names()
    |> report_transcript_sync(
      :changed,
      length(changes.entries),
      calls,
      length(changes.pin_changes)
    )
  end

  @spec reuse_transcript(state(), Cursor.t(), pos_integer()) :: state()
  defp reuse_transcript(state, cursor, calls) do
    projection =
      state.workspace.agent_ui.panel.transcript
      |> TranscriptProjection.prepare(presentation_context(state))
      |> TranscriptProjection.advance_source_cursor(cursor)

    state
    |> install_projection(projection, :keep)
    |> report_transcript_sync(:unchanged, 0, calls)
  end

  @spec install_projection(state(), TranscriptProjection.t(), :keep | :follow | non_neg_integer()) ::
          state()
  defp install_projection(
         %{workspace: %{agent_ui: %{panel: %Panel{transcript: projection}}}} = state,
         projection,
         :keep
       ),
       do: state

  defp install_projection(state, next, reading) do
    panel = state.workspace.agent_ui.panel
    reading = newly_landed_reading(panel.transcript, next, reading)
    panel = Panel.install_transcript(panel, next, reading)
    MingaEditor.Shell.Traditional.Workflow.install_agent_panel(state, panel)
  end

  defp newly_landed_reading(
         %{provenance_jump: %{landed?: false}},
         %{provenance_jump: %{landed?: true, target: {:message_id, id}}} = next,
         reading
       ),
       do: TranscriptProjection.start_line(next, id) || reading

  defp newly_landed_reading(_previous, _next, reading), do: reading

  @spec presentation_context(state()) :: TranscriptProjection.presentation_context()
  defp presentation_context(state) do
    {empty_state_for_panel(state.workspace.agent_ui.panel), state.appearance.theme.syntax,
     &style_message/3}
  end

  @doc "Records a switch whose Session could not provide a transcript."
  @spec report_unavailable_arrival(state(), 1 | 2) :: state()
  def report_unavailable_arrival(state, calls),
    do: report_transcript_sync(state, :unavailable, 0, calls)

  @spec report_transcript_sync(
          state(),
          :unchanged | :changed | :reset | :unavailable,
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: state()
  defp report_transcript_sync(state, outcome, entries_read, session_calls, pin_facts \\ 0) do
    measurements = %{
      entries_read: entries_read,
      pin_facts: pin_facts,
      session_calls: session_calls
    }

    Minga.Telemetry.execute([:minga, :agent, :transcript_sync], measurements, %{outcome: outcome})

    state
  end

  @doc "Installs an explicitly supplied remote transcript without using the local cursor contract."
  @spec cache_messages(state(), [term()]) :: state()
  def cache_messages(state, messages) do
    session = Runtime.active_session(state.shell_runtime)
    replace_remote_messages(state, messages, session)
  end

  defp replace_remote_messages(state, [], nil) do
    projection = TranscriptProjection.clear(state.workspace.agent_ui.panel.transcript)
    install_projection(state, projection, :keep)
  end

  defp replace_remote_messages(state, messages, session) do
    panel = state.workspace.agent_ui.panel
    {entries, pins} = remote_entries(messages, session)

    projection =
      TranscriptProjection.replace(
        panel.transcript,
        entries,
        pins,
        nil,
        presentation_context(state)
      )

    install_projection(state, projection, :keep)
  catch
    :exit, _ -> state
  end

  defp refresh_remote_messages(state, messages, session) do
    {entries, pins} = remote_entries(messages, session)

    projection =
      TranscriptProjection.refresh_remote(
        state.workspace.agent_ui.panel.transcript,
        entries,
        pins,
        presentation_context(state)
      )

    install_projection(state, projection, :keep)
  catch
    :exit, _ -> state
  end

  defp remote_entries([], _session), do: {[], MapSet.new()}

  defp remote_entries(messages, session) do
    {pairs, pins} = remote_transcript_pairs(messages, session)

    entries =
      Enum.with_index(pairs, fn {id, message}, ordinal ->
        Entry.new(TranscriptEntry.new(id, message), ordinal, 0)
      end)

    {entries, pins}
  end

  defp remote_transcript_pairs(messages, session)
       when is_pid(session) and node(session) != node() do
    # minga:allow-blocking — Editor, remote sessions only; no transcript cursor over distribution
    case AgentSession.messages_with_ids(session) do
      [] ->
        numbered_messages(messages)

      pairs ->
        # minga:allow-blocking — Editor, remote sessions only; pins for the pairs read above
        {pairs, AgentSession.pinned_ids(session)}
    end
  end

  defp remote_transcript_pairs(messages, _session), do: numbered_messages(messages)

  defp numbered_messages(messages),
    do: {Enum.with_index(messages, fn message, index -> {index + 1, message} end), MapSet.new()}

  @spec safe_session_messages(pid()) :: {:ok, [term()]} | :dead_session
  defp safe_session_messages(session) do
    # minga:allow-blocking — Editor, remote sessions only; no transcript cursor over distribution
    {:ok, AgentSession.messages(session)}
  catch
    :exit, _ -> :dead_session
  end

  @spec empty_state_for_panel(Panel.t()) :: Transcript.empty_state()
  defp empty_state_for_panel(%Panel{credential_readiness: :checking}), do: :checking

  defp empty_state_for_panel(panel) do
    empty_state_for_status(configured_model?(panel.model_name), panel.credentials_configured)
  end

  @spec empty_state_for_status(boolean(), boolean()) :: Transcript.empty_state()
  defp empty_state_for_status(false, _credentials_configured), do: :no_model
  defp empty_state_for_status(true, false), do: :credentials_missing
  defp empty_state_for_status(true, true), do: nil

  @spec configured_model?(String.t()) :: boolean()
  defp configured_model?(model) when model in ["", "unknown"], do: false
  defp configured_model?(model), do: model != AgentConfig.unconfigured_model()

  @spec update_transcript_names(state()) :: state()
  defp update_transcript_names(state) do
    {user, assistant, _turn_count} =
      TranscriptProjection.names_and_turns(state.workspace.agent_ui.panel.transcript)

    state
    |> maybe_rename_workspace_from_assistant(assistant)
    |> maybe_update_tab_label(user)
  end

  @spec maybe_rename_workspace_from_assistant(state(), String.t() | nil) :: state()
  defp maybe_rename_workspace_from_assistant(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tab_bar}}} = state,
         text
       )
       when is_binary(text) do
    with session when is_pid(session) <- Runtime.active_session(state.shell_runtime),
         %Workspace{custom_name: nil, id: id} <-
           TabBar.find_workspace_by_session(tab_bar, session) do
      WorkspaceWorkflow.install_auto_named_workspace(state, id, text)
    else
      _unavailable -> state
    end
  end

  defp maybe_rename_workspace_from_assistant(state, _messages), do: state

  @spec maybe_update_tab_label(state(), String.t() | nil) :: state()
  defp maybe_update_tab_label(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{active_id: active_id} = tab_bar}}} = state,
         text
       )
       when is_binary(text) do
    with %Tab{kind: :agent, label: label} when is_binary(label) <- TabBar.active(tab_bar),
         true <- default_agent_label?(label) do
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

  @spec truncate_label(String.t(), pos_integer()) :: String.t()
  defp truncate_label(text, max) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if String.length(line) > max do
      String.slice(line, 0, max - 1) <> "\u{2026}"
    else
      line
    end
  end

  @doc "Applies the current theme to the installed transcript without reading Session history."
  @spec restyle_transcript(state()) :: state()
  def restyle_transcript(
        %{workspace: %{agent_ui: %{panel: %Panel{transcript: %{index: nil}}}}} = state
      ),
      do: state

  def restyle_transcript(state) do
    projection =
      TranscriptProjection.prepare(
        state.workspace.agent_ui.panel.transcript,
        presentation_context(state)
      )

    install_projection(state, projection, :keep)
  end

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
end
