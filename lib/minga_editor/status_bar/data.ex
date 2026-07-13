defmodule MingaEditor.StatusBar.Data do
  @moduledoc """
  Tagged-union data struct for the global status bar.

  Computed once per frame from editor state and consumed by the semantic emit
  path, which encodes it as the 0x76 (`gui_status_bar`) structured opcode for
  every live frontend.

  The two variants reflect the two kinds of focused window content:
  - `{:buffer, t:buffer_data()}` — a normal buffer window
  - `{:agent, t:agent_data()}` — an agent chat window
  """

  alias Minga.Buffer
  alias Minga.Diagnostics
  alias Minga.Config.ModelineSegments
  alias MingaEditor.Editing
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.Window.Content
  alias Minga.Config.Options
  alias Minga.Git
  alias Minga.Git.MergeConflict
  alias Minga.Git.Repo, as: GitRepo
  alias Minga.LSP.SyncServer
  alias MingaEditor.Shell.Traditional.Modeline
  alias MingaAgent.StatusCommand
  alias MingaEditor.UI.Theme
  alias MingaEditor.Session.ChromeState

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Git diff summary: {added, modified, deleted} line counts."
  @type git_diff_summary :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil

  @typedoc "LSP connection status."
  @type lsp_status :: :ready | :initializing | :starting | :error | :none

  @typedoc "Parser availability status."
  @type parser_status :: :available | :unavailable | :restarting

  @typedoc "Indentation display information."
  @type indent_type :: :spaces | :tabs

  @typedoc "Visual selection size display information."
  @type selection_info :: {:chars, non_neg_integer()} | {:lines, pos_integer()} | nil

  @typedoc "Data for a focused buffer window."
  @type buffer_data :: %{
          optional(:modeline_segments) => Modeline.gui_segments(),
          mode: Minga.Mode.mode(),
          mode_state: Minga.Mode.state() | nil,
          safe_mode: boolean(),
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer(),
          line_count: non_neg_integer(),
          file_name: String.t(),
          filetype: atom(),
          dirty: boolean(),
          git_branch: String.t() | nil,
          git_diff_summary: git_diff_summary(),
          git_degraded: boolean(),
          diagnostic_counts:
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil,
          diagnostic_hint: String.t() | nil,
          indent_type: indent_type(),
          indent_size: pos_integer(),
          selection_info: selection_info(),
          lsp_status: lsp_status(),
          parser_status: parser_status(),
          buf_index: pos_integer(),
          buf_count: non_neg_integer(),
          macro_recording: {true, String.t()} | false,
          agent_status: AgentState.status(),
          active_tool_name: String.t() | nil,
          agent_status_command: String.t() | nil,
          agent_theme_colors: Theme.Agent.t() | nil,
          background_subagent_count: non_neg_integer(),
          active_background_subagent_label: String.t() | nil,
          status_msg: String.t() | nil,
          selected_operation: Operation.t() | nil,
          pending_keys: String.t(),
          workspace_label: String.t(),
          workspace_draft_count: non_neg_integer(),
          workspace_conflict_count: non_neg_integer(),
          merge_conflict_count: non_neg_integer()
        }

  @typedoc "Data for a focused agent chat window. Includes background buffer context so the status bar layout stays stable across mode switches."
  @type agent_data :: %{
          optional(:modeline_segments) => Modeline.gui_segments(),
          mode: Minga.Mode.mode(),
          mode_state: Minga.Mode.state() | nil,
          safe_mode: boolean(),
          model_name: String.t(),
          session_status: AgentState.status(),
          message_count: non_neg_integer(),
          macro_recording: {true, String.t()} | false,
          agent_status: AgentState.status(),
          active_tool_name: String.t() | nil,
          agent_status_command: String.t() | nil,
          agent_theme_colors: Theme.Agent.t() | nil,
          # Background buffer context (same fields as buffer_data)
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer(),
          line_count: non_neg_integer(),
          file_name: String.t(),
          filetype: atom(),
          dirty: boolean(),
          git_branch: String.t() | nil,
          git_diff_summary: git_diff_summary(),
          git_degraded: boolean(),
          diagnostic_counts:
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil,
          diagnostic_hint: String.t() | nil,
          indent_type: indent_type(),
          indent_size: pos_integer(),
          selection_info: selection_info(),
          lsp_status: lsp_status(),
          parser_status: parser_status(),
          buf_index: pos_integer(),
          buf_count: non_neg_integer(),
          background_subagent_count: non_neg_integer(),
          active_background_subagent_label: String.t() | nil,
          status_msg: String.t() | nil,
          selected_operation: Operation.t() | nil,
          pending_keys: String.t(),
          workspace_label: String.t(),
          workspace_draft_count: non_neg_integer(),
          workspace_conflict_count: non_neg_integer(),
          merge_conflict_count: non_neg_integer()
        }

  @typedoc "Tagged union: buffer or agent variant."
  @type t :: {:buffer, buffer_data()} | {:agent, agent_data()}

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Builds the status bar data from the current editor state.

  Inspects the active window's content type and returns the appropriate
  tagged variant. Called once per render frame before the Chrome stage.
  """
  @spec from_state(EditorState.t() | map()) :: t()
  def from_state(state) do
    active_window = Map.get(state.workspace.windows.map, state.workspace.windows.active)

    if active_window != nil and Content.agent_chat?(active_window.content) do
      {:agent, build_agent_data(state)}
    else
      {:buffer, build_buffer_data(state)}
    end
  end

  @doc "Attaches GUI-ready configured modeline segments to status bar data."
  @spec with_modeline_segments(t(), Theme.t()) :: t()
  @spec with_modeline_segments(t(), Theme.t(), ModelineSegments.table()) :: t()
  def with_modeline_segments(status_bar_data, theme, modeline_segments_table \\ ModelineSegments)

  def with_modeline_segments({:buffer, data}, theme, modeline_segments_table),
    do: {:buffer, attach_modeline_segments(data, theme, modeline_segments_table)}

  def with_modeline_segments({:agent, data}, theme, modeline_segments_table),
    do: {:agent, attach_modeline_segments(data, theme, modeline_segments_table)}

  # ── Buffer variant ─────────────────────────────────────────────────────────

  @spec build_buffer_data(EditorState.t() | map()) :: buffer_data()
  defp build_buffer_data(state) do
    buf = state.workspace.buffers.active
    {line, col} = if buf, do: Buffer.cursor(buf), else: {0, 0}
    line_count = if buf, do: Buffer.line_count(buf), else: 1
    file_name = if buf, do: buf_display_name(buf), else: no_buffer_file_name(state)
    dirty = buf != nil and Buffer.dirty?(buf)
    filetype = if buf, do: buffer_filetype(buf), else: :text
    file_path = if buf, do: buffer_file_path(buf), else: nil

    {git_branch, git_diff_summary} = git_modeline_data(buf)
    git_degraded = git_degraded?(file_path)
    diagnostic_counts = diagnostic_modeline_data_from_path(file_path)

    # Fetch diagnostic hint for the current cursor line (shown in status bar
    # center segment when idle, replaces the old cell-grid minibuffer hint)
    diagnostic_hint = cursor_line_diagnostic_hint_from_path(file_path, line)

    mode = Minga.Editing.mode(state)
    mode_state = Editing.mode_state(state)
    {indent_type, indent_size} = indent_info(state, buf, filetype)
    selection_info = selection_info(mode, mode_state, buf, {line, col})

    agent = agent_state(state)
    background = background_subagent_summary(state)
    workspace = workspace_modeline_summary(state)

    %{
      mode: mode,
      mode_state: mode_state,
      safe_mode: Minga.SafeMode.active?(),
      cursor_line: line,
      cursor_col: col,
      line_count: line_count,
      file_name: file_name,
      filetype: filetype,
      dirty: dirty,
      git_branch: git_branch,
      git_diff_summary: git_diff_summary,
      git_degraded: git_degraded,
      diagnostic_counts: diagnostic_counts,
      diagnostic_hint: diagnostic_hint,
      indent_type: indent_type,
      indent_size: indent_size,
      selection_info: selection_info,
      lsp_status: state.lsp.status,
      parser_status: state.parser_status,
      buf_index: state.workspace.buffers.active_index + 1,
      buf_count: Enum.count(state.workspace.buffers.list),
      macro_recording: Minga.Editing.macro_recording_status(state),
      agent_status: agent.runtime.status,
      active_tool_name: agent.runtime.active_tool_name,
      agent_status_command: agent_status_command_content(state, agent),
      agent_theme_colors: if(agent.runtime.status, do: Theme.agent_theme(state.theme), else: nil),
      background_subagent_count: background.count,
      active_background_subagent_label: background.label,
      status_msg: status_message(state),
      selected_operation: OperationFeedback.selected_from(state),
      pending_keys: pending_keys(state, mode, mode_state),
      workspace_label: workspace.label,
      workspace_draft_count: workspace.draft_count,
      workspace_conflict_count: workspace.conflict_count,
      merge_conflict_count: merge_conflict_count(buf)
    }
  end

  # ── Pending-key echo (vim showcmd) ─────────────────────────────────────────

  @spec pending_keys(EditorState.t() | map(), Minga.Mode.mode(), Minga.Mode.state() | nil) ::
          String.t()
  # Which-key takes over the acknowledgment once its popup is showing, so the
  # instant echo clears the moment which-key opens (#2666 AC #2). When a
  # sequence resolves or is aborted, the FSM count/pending/leader fields reset,
  # so the derived string is empty again with no extra bookkeeping (#2666 AC #3).
  defp pending_keys(state, mode, mode_state) do
    if whichkey_showing?(state) do
      ""
    else
      register_prefix(active_register_name(state)) <> Minga.Mode.pending_keys(mode, mode_state)
    end
  end

  @spec whichkey_showing?(EditorState.t() | map()) :: boolean()
  defp whichkey_showing?(%EditorState{shell_runtime: %{state: %{whichkey: %{show: true}}}}),
    do: true

  defp whichkey_showing?(%{shell_state: %{whichkey: %{show: true}}}), do: true
  defp whichkey_showing?(_state), do: false

  @spec active_register_name(EditorState.t() | map()) :: String.t()
  defp active_register_name(%EditorState{} = state), do: Editing.active_register(state)
  defp active_register_name(_state), do: ""

  @spec agent_state(EditorState.t() | map()) :: AgentState.t()
  defp agent_state(%EditorState{} = state), do: AgentAccess.agent(state)
  defp agent_state(%{shell_state: %{agent: %AgentState{} = agent}}), do: agent
  defp agent_state(_state), do: %AgentState{}

  @spec status_message(EditorState.t() | map()) :: String.t() | nil
  defp status_message(%EditorState{} = state), do: EditorState.status_msg(state)
  defp status_message(%{shell_state: %{status_msg: status_msg}}), do: status_msg
  defp status_message(_state), do: nil

  @spec agent_session(EditorState.t() | map()) :: pid() | nil
  defp agent_session(%EditorState{} = state), do: AgentAccess.session(state)

  defp agent_session(%{shell: shell, shell_state: shell_state}) when is_atom(shell),
    do: shell.active_session(shell_state)

  defp agent_session(_state), do: nil

  @spec register_prefix(String.t()) :: String.t()
  defp register_prefix(""), do: ""
  defp register_prefix(name), do: "\"" <> name

  # In the zero-buffers launchpad (#2689) the file segment stays empty
  # instead of advertising a "[no file]" placeholder; any other nil-buffer
  # context (transient races) keeps the placeholder.
  @spec no_buffer_file_name(EditorState.t() | map()) :: String.t()
  defp no_buffer_file_name(state) do
    if state.workspace.launchpad, do: "", else: "[no file]"
  end

  @spec buf_display_name(pid()) :: String.t()
  defp buf_display_name(buf) do
    Buffer.display_name(buf)
  catch
    :exit, _ -> "[no file]"
  end

  @spec buffer_filetype(pid()) :: atom()
  defp buffer_filetype(buf) do
    Buffer.filetype(buf) || :text
  catch
    :exit, _ -> :text
  end

  @spec buffer_file_path(pid()) :: String.t() | nil
  defp buffer_file_path(buf) do
    Buffer.file_path(buf)
  catch
    :exit, _ -> nil
  end

  @spec indent_info(EditorState.t() | map(), pid() | nil, atom()) ::
          {indent_type(), pos_integer()}
  defp indent_info(state, buf, filetype) do
    options_server = options_server(state)
    indent_type = buffer_option(buf, options_server, filetype, :indent_with)
    indent_size = buffer_option(buf, options_server, filetype, :tab_width)
    {normalize_indent_type(indent_type), normalize_indent_size(indent_size)}
  end

  @spec buffer_option(pid() | nil, Options.server(), atom(), Options.option_name()) :: term()
  defp buffer_option(buf, options_server, filetype, option) when is_pid(buf) do
    case Buffer.get_option(buf, option) do
      :error -> Options.get_for_filetype(options_server, option, filetype)
      value -> value
    end
  catch
    :exit, _ -> Options.get_for_filetype(options_server, option, filetype)
  end

  defp buffer_option(nil, options_server, filetype, option) do
    Options.get_for_filetype(options_server, option, filetype)
  end

  @spec options_server(EditorState.t() | map()) :: Options.server()
  defp options_server(%EditorState{} = state), do: EditorState.options_server(state)
  defp options_server(%{options_server: server}), do: server
  defp options_server(_state), do: Options.default_server()

  @spec normalize_indent_type(term()) :: indent_type()
  defp normalize_indent_type(:tabs), do: :tabs
  defp normalize_indent_type(_value), do: :spaces

  @spec normalize_indent_size(term()) :: pos_integer()
  defp normalize_indent_size(value) when is_integer(value) and value > 0, do: value
  defp normalize_indent_size(_value), do: 2

  @spec selection_info(
          Minga.Mode.mode(),
          Minga.Mode.state() | nil,
          pid() | nil,
          Buffer.position()
        ) ::
          selection_info()
  defp selection_info(
         :visual,
         %{visual_type: :line, visual_anchor: {anchor_line, _}},
         _buf,
         {line, _}
       ) do
    {:lines, abs(anchor_line - line) + 1}
  end

  defp selection_info(:visual, %{visual_type: :char, visual_anchor: anchor}, buf, cursor)
       when is_pid(buf) do
    {:chars, Buffer.content_range_length(buf, anchor, cursor)}
  catch
    :exit, _ -> nil
  end

  defp selection_info(_mode, _mode_state, _buf, _cursor), do: nil

  # ── Agent variant ──────────────────────────────────────────────────────────

  @spec build_agent_data(EditorState.t() | map()) :: agent_data()
  defp build_agent_data(state) do
    agent = agent_state(state)
    panel = AgentAccess.panel(state)
    session = agent_session(state)

    message_count = agent_message_count(session)

    model_name = if panel.model_name != "", do: panel.model_name, else: "Agent"

    # Pull background buffer context so the status bar stays stable
    buf = state.workspace.buffers.active
    {line, col} = if buf, do: Buffer.cursor(buf), else: {0, 0}
    line_count = if buf, do: Buffer.line_count(buf), else: 1
    file_name = if buf, do: buf_display_name(buf), else: "[no file]"
    dirty = buf != nil and Buffer.dirty?(buf)
    filetype = if buf, do: buffer_filetype(buf), else: :text
    file_path = if buf, do: buffer_file_path(buf), else: nil

    {git_branch, git_diff_summary} = git_modeline_data(buf)
    git_degraded = git_degraded?(file_path)
    diagnostic_counts = diagnostic_modeline_data_from_path(file_path)
    diagnostic_hint = cursor_line_diagnostic_hint_from_path(file_path, line)
    mode = Minga.Editing.mode(state)
    mode_state = Editing.mode_state(state)
    {indent_type, indent_size} = indent_info(state, buf, filetype)
    selection_info = selection_info(mode, mode_state, buf, {line, col})
    background = background_subagent_summary(state)
    workspace = workspace_modeline_summary(state)

    %{
      mode: mode,
      mode_state: mode_state,
      safe_mode: Minga.SafeMode.active?(),
      model_name: model_name,
      session_status: agent.runtime.status,
      message_count: message_count,
      macro_recording: Minga.Editing.macro_recording_status(state),
      agent_status: agent.runtime.status,
      active_tool_name: agent.runtime.active_tool_name,
      agent_status_command: agent_status_command_content(state, agent),
      agent_theme_colors: Theme.agent_theme(state.theme),
      # Background buffer context
      cursor_line: line,
      cursor_col: col,
      line_count: line_count,
      file_name: file_name,
      filetype: filetype,
      dirty: dirty,
      git_branch: git_branch,
      git_diff_summary: git_diff_summary,
      git_degraded: git_degraded,
      diagnostic_counts: diagnostic_counts,
      diagnostic_hint: diagnostic_hint,
      indent_type: indent_type,
      indent_size: indent_size,
      selection_info: selection_info,
      lsp_status: state.lsp.status,
      parser_status: state.parser_status,
      buf_index: state.workspace.buffers.active_index + 1,
      buf_count: Enum.count(state.workspace.buffers.list),
      background_subagent_count: background.count,
      active_background_subagent_label: background.label,
      status_msg: status_message(state),
      selected_operation: OperationFeedback.selected_from(state),
      pending_keys: pending_keys(state, mode, mode_state),
      workspace_label: workspace.label,
      workspace_draft_count: workspace.draft_count,
      workspace_conflict_count: workspace.conflict_count,
      merge_conflict_count: merge_conflict_count(buf)
    }
  end

  @spec agent_message_count(pid() | nil) :: non_neg_integer()
  defp agent_message_count(session) when is_pid(session) do
    case safe_session_metadata(session) do
      %MingaAgent.SessionMetadata{turn_count: count} when is_integer(count) and count >= 0 ->
        count

      _other ->
        0
    end
  end

  defp agent_message_count(_session), do: 0

  @spec agent_status_command_content(EditorState.t() | map(), AgentState.t()) :: String.t() | nil
  defp agent_status_command_content(state, agent) do
    StatusCommand.content(agent_status_command_context(state, agent))
  end

  @spec agent_status_command_context(EditorState.t() | map(), AgentState.t()) ::
          StatusCommand.context()
  defp agent_status_command_context(state, agent) do
    session = AgentAccess.session(state)
    {session_id, session_model, workdir} = session_context(session)
    panel = AgentAccess.panel(state)

    %{
      session_id: session_id,
      model: model_name(panel.model_name, session_model),
      status: agent.runtime.status,
      workdir: workdir || File.cwd!()
    }
  end

  @spec session_context(pid() | nil) :: {String.t() | nil, String.t() | nil, String.t() | nil}
  defp session_context(session) when is_pid(session) do
    case safe_session_metadata(session) do
      %MingaAgent.SessionMetadata{} = metadata ->
        {metadata.id, metadata.model_name, metadata.workdir}

      _other ->
        {nil, nil, nil}
    end
  end

  defp session_context(_session), do: {nil, nil, nil}

  @spec safe_session_metadata(pid()) :: term()
  defp safe_session_metadata(session) do
    GenServer.call(session, :metadata)
  catch
    :exit, _ -> nil
  end

  @spec model_name(String.t(), String.t() | nil) :: String.t()
  defp model_name(panel_model, _session_model)
       when is_binary(panel_model) and panel_model not in ["", "unknown"],
       do: panel_model

  defp model_name(_panel_model, session_model)
       when is_binary(session_model) and session_model not in ["", "unknown"],
       do: session_model

  defp model_name(_panel_model, _session_model), do: "No model configured"

  @spec attach_modeline_segments(map(), Theme.t(), ModelineSegments.table()) ::
          buffer_data() | agent_data()
  defp attach_modeline_segments(data, theme, modeline_segments_table) do
    Map.put(
      data,
      :modeline_segments,
      Modeline.gui_segments(data_to_modeline_data(data), theme, modeline_segments_table)
    )
  end

  # ── Git helpers ────────────────────────────────────────────────────────────

  @doc "Returns {branch_name | nil, diff_summary | nil} for the status bar."
  @spec git_modeline_data(pid() | nil) :: {String.t() | nil, git_diff_summary()}
  def git_modeline_data(nil), do: {nil, nil}

  def git_modeline_data(buf) when is_pid(buf) do
    case Git.tracking_pid(buf) do
      nil ->
        {nil, nil}

      git_pid ->
        try do
          Git.modeline_info(git_pid)
        catch
          :exit, _ -> {nil, nil}
        end
    end
  end

  @doc """
  Returns true when the tracked repo's cached status is degraded for `path`.

  Reads the repo's cache-only snapshot (no git shell-out). Degraded means the
  last `git status` was trimmed (e.g. timed out on a huge full checkout), so the
  modeline shows a visible indicator rather than implying the status is complete.
  """
  @spec git_degraded?(String.t() | nil) :: boolean()
  def git_degraded?(nil), do: false

  def git_degraded?(path) when is_binary(path) do
    case GitRepo.cached_status_for_path(path) do
      {:ok, %{degraded?: degraded?}} -> degraded?
      :not_tracked -> false
    end
  end

  @spec merge_conflict_count(pid() | nil) :: non_neg_integer()
  defp merge_conflict_count(nil), do: 0

  defp merge_conflict_count(buf) when is_pid(buf) do
    case Git.tracking_pid(buf) do
      nil -> buf |> Buffer.content() |> MergeConflict.parse() |> Enum.count()
      git_pid -> Git.conflict_count(git_pid)
    end
  catch
    :exit, _ -> 0
  end

  @doc "Returns the diagnostic count 4-tuple for the active buffer, or nil."
  @spec diagnostic_modeline_data(pid() | nil) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  def diagnostic_modeline_data(nil), do: nil

  def diagnostic_modeline_data(buf) when is_pid(buf) do
    path =
      try do
        Buffer.file_path(buf)
      catch
        :exit, _ -> nil
      end

    diagnostic_modeline_data_from_path(path)
  end

  @spec diagnostic_modeline_data_from_path(String.t() | nil) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  defp diagnostic_modeline_data_from_path(nil), do: nil

  defp diagnostic_modeline_data_from_path(path) do
    Diagnostics.count_tuple(SyncServer.path_to_uri(path))
  end

  # ── Diagnostic hint for status bar ──────────────────────────────────────────

  @doc """
  Returns the first diagnostic message on the given cursor line, formatted
  as a human-readable hint string (icon + message + source). Returns nil
  if no diagnostics exist on that line.

  Used by the GUI status bar center segment to show diagnostic context
  when idle (no status message, no active minibuffer).
  """
  @spec cursor_line_diagnostic_hint(pid() | nil, non_neg_integer()) :: String.t() | nil
  def cursor_line_diagnostic_hint(nil, _line), do: nil

  def cursor_line_diagnostic_hint(buf, line) when is_pid(buf) do
    file_path =
      try do
        Buffer.file_path(buf)
      catch
        :exit, _ -> nil
      end

    cursor_line_diagnostic_hint_from_path(file_path, line)
  end

  @spec cursor_line_diagnostic_hint_from_path(String.t() | nil, non_neg_integer()) ::
          String.t() | nil
  defp cursor_line_diagnostic_hint_from_path(nil, _line), do: nil

  defp cursor_line_diagnostic_hint_from_path(path, line) do
    path
    |> SyncServer.path_to_uri()
    |> Diagnostics.for_uri()
    |> Enum.find(fn d -> d.range.start_line == line end)
    |> format_diagnostic_hint()
  end

  @spec format_diagnostic_hint(Diagnostics.Diagnostic.t() | nil) :: String.t() | nil
  defp format_diagnostic_hint(nil), do: nil

  defp format_diagnostic_hint(diag) do
    icon = diagnostic_severity_icon(diag.severity)
    source = if diag.source, do: " [#{diag.source}]", else: ""
    "#{icon} #{diag.message}#{source}"
  end

  @spec diagnostic_severity_icon(Diagnostics.Diagnostic.severity()) :: String.t()
  defp diagnostic_severity_icon(:error), do: "✖"
  defp diagnostic_severity_icon(:warning), do: "⚠"
  defp diagnostic_severity_icon(:info), do: "ℹ"
  defp diagnostic_severity_icon(:hint), do: "💡"

  # ── Adapters for Modeline.render/5 ────────────────────────────────────────

  @doc """
  Converts a `StatusBar.Data.t()` to the map shape expected by `Modeline.render/5`.

  Both variants carry the same buffer fields and produce identical modeline data.
  """
  @spec to_modeline_data(t()) :: MingaEditor.Shell.Traditional.Modeline.modeline_data()
  def to_modeline_data({_variant, d}), do: data_to_modeline_data(d)

  @spec data_to_modeline_data(map()) :: MingaEditor.Shell.Traditional.Modeline.modeline_data()
  defp data_to_modeline_data(d) do
    %{
      mode: d.mode,
      mode_state: d.mode_state,
      safe_mode: Map.get(d, :safe_mode, false),
      file_name: d.file_name,
      filetype: d.filetype,
      dirty_marker: if(d.dirty, do: " ● ", else: ""),
      cursor_line: d.cursor_line,
      cursor_col: d.cursor_col,
      line_count: d.line_count,
      buf_index: d.buf_index,
      buf_count: d.buf_count,
      macro_recording: d.macro_recording,
      agent_status: d.agent_status,
      active_tool_name: Map.get(d, :active_tool_name),
      agent_status_command: Map.get(d, :agent_status_command),
      agent_theme_colors: d.agent_theme_colors,
      lsp_status: d.lsp_status,
      parser_status: d.parser_status,
      git_branch: d.git_branch,
      git_diff_summary: d.git_diff_summary,
      git_degraded: Map.get(d, :git_degraded, false),
      diagnostic_counts: d.diagnostic_counts,
      indent_type: d.indent_type,
      indent_size: d.indent_size,
      selection_info: d.selection_info,
      background_subagent_count: d.background_subagent_count,
      active_background_subagent_label: d.active_background_subagent_label,
      workspace_label: d.workspace_label,
      workspace_draft_count: d.workspace_draft_count,
      workspace_conflict_count: d.workspace_conflict_count,
      merge_conflict_count: d.merge_conflict_count
    }
  end

  @spec workspace_modeline_summary(EditorState.t() | map()) :: %{
          label: String.t(),
          draft_count: non_neg_integer(),
          conflict_count: non_neg_integer()
        }
  defp workspace_modeline_summary(state) do
    chrome_state = ChromeState.from_editor_state(state)

    active_workspace =
      Enum.find(chrome_state.workspaces, fn workspace ->
        workspace.id == chrome_state.active_workspace_id
      end)

    %{
      label: if(active_workspace, do: active_workspace.label, else: "Files"),
      draft_count: chrome_state.draft_count,
      conflict_count: chrome_state.conflict_count
    }
  end

  @spec background_subagent_summary(EditorState.t() | map()) :: %{
          count: non_neg_integer(),
          label: String.t() | nil
        }
  defp background_subagent_summary(%EditorState{shell_runtime: %{state: %{tab_bar: tb}}}) do
    background_subagent_summary(tb)
  end

  defp background_subagent_summary(%{shell_state: %{tab_bar: tb}}) do
    background_subagent_summary(tb)
  end

  @spec background_subagent_summary(MingaEditor.State.TabBar.t()) :: %{
          count: non_neg_integer(),
          label: String.t() | nil
        }
  defp background_subagent_summary(%MingaEditor.State.TabBar{} = tb) do
    tabs = Enum.filter(tb.tabs, &MingaEditor.State.Tab.background_subagent?/1)
    running = Enum.filter(tabs, &(&1.agent_status in [:thinking, :tool_executing]))
    active = Enum.find(tabs, &(&1.id == tb.active_id))
    selected = active || List.first(running) || List.first(tabs)

    %{
      count: Enum.count(running),
      label: background_subagent_label(selected)
    }
  end

  defp background_subagent_summary(_state), do: %{count: 0, label: nil}

  @spec background_subagent_label(MingaEditor.State.Tab.t() | nil) :: String.t() | nil
  defp background_subagent_label(%MingaEditor.State.Tab{
         background_subagent: %MingaAgent.Subagent.Handle{} = handle
       }) do
    MingaAgent.Subagent.Handle.label(handle)
  end

  defp background_subagent_label(_tab), do: nil
end
