defmodule MingaEditor.StatusBar.Data do
  @moduledoc """
  Typed editor snapshot for the global status bar.

  Computed once per frame from editor state and consumed by the semantic emit
  path, which encodes it as the 0x76 (`gui_status_bar`) structured opcode for
  every live frontend.
  """

  alias Minga.Buffer, as: BufferAPI
  alias Minga.Config.ModelineSegments
  alias Minga.Config.Options
  alias Minga.Diagnostics
  alias Minga.Git
  alias Minga.Git.Repo, as: GitRepo
  alias Minga.LSP.SyncServer
  alias Minga.RenderModel.UI.StatusBar.Agent, as: SemanticStatusAgent
  alias Minga.RenderModel.UI.StatusBar.Cursor, as: StatusCursor
  alias Minga.RenderModel.UI.StatusBar.Data, as: SemanticStatusData
  alias Minga.RenderModel.UI.StatusBar.Diagnostics, as: StatusDiagnostics
  alias Minga.RenderModel.UI.StatusBar.File, as: StatusFile
  alias Minga.RenderModel.UI.StatusBar.Git, as: StatusGit
  alias Minga.RenderModel.UI.StatusBar.Indent, as: StatusIndent
  alias Minga.RenderModel.UI.StatusBar.Language, as: StatusLanguage
  alias Minga.RenderModel.UI.StatusBar.Selection, as: StatusSelection
  alias Minga.RenderModel.UI.StatusBar.Workspace, as: StatusWorkspace
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.StatusCommand
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.WorkspaceStatus
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Editing
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Shell.Traditional.Modeline
  alias MingaEditor.Shell.Traditional.Notice
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.RouteUsage
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent, as: TabAgent
  alias MingaEditor.StatusBar.Data.Agent, as: StatusAgent
  alias MingaEditor.StatusBar.Data.Buffer, as: StatusBuffer
  alias MingaEditor.StatusBar.Data.Common
  alias MingaEditor.UI.Theme
  alias MingaEditor.Window.Content

  @typedoc "Git diff summary: {added, modified, deleted} line counts."
  @type git_diff_summary :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil

  @typedoc "Parser availability status."
  @type parser_status :: :available | :unavailable | :restarting

  @typedoc "Indentation display information."
  @type indent_type :: :spaces | :tabs

  @typedoc "Visual selection size display information."
  @type selection_info :: {:chars, non_neg_integer()} | {:lines, pos_integer()} | nil

  @type t :: %__MODULE__{
          common: Common.t(),
          content: StatusBuffer.t() | StatusAgent.t()
        }

  @enforce_keys [:common, :content]
  defstruct @enforce_keys

  @doc """
  Builds the status bar data from the current editor state.

  Inspects the active window's content type and returns the appropriate typed
  content marker. Called once per render frame before the Chrome stage.
  """
  @spec from_state(EditorState.t() | map()) :: t()
  def from_state(state) do
    active_window = Map.get(state.workspace.windows.map, state.workspace.windows.active)

    if active_window != nil and Content.agent_chat?(active_window.content) do
      build_agent_data(state)
    else
      build_buffer_data(state)
    end
  end

  @doc "Attaches GUI-ready configured modeline segments to status bar data."
  @spec with_modeline_segments(t(), Theme.t()) :: t()
  @spec with_modeline_segments(t(), Theme.t(), ModelineSegments.table()) :: t()
  def with_modeline_segments(status_bar_data, theme, modeline_segments_table \\ ModelineSegments)

  def with_modeline_segments(
        %__MODULE__{common: %Common{status: %SemanticStatusData{} = status} = common} = data,
        theme,
        modeline_segments_table
      ) do
    segments =
      Modeline.gui_segments(data_to_modeline_data(common), theme, modeline_segments_table)

    %{data | common: %{common | status: %{status | modeline_segments: segments}}}
  end

  # ── Buffer variant ─────────────────────────────────────────────────────────

  @spec build_buffer_data(EditorState.t() | map()) :: t()
  defp build_buffer_data(state) do
    %__MODULE__{
      common: build_common_data(state, no_buffer_file_name(state)),
      content: %StatusBuffer{}
    }
  end

  @spec build_common_data(EditorState.t() | map(), String.t()) :: Common.t()
  defp build_common_data(state, no_buffer_file_name) do
    buf = state.workspace.buffers.active
    {line, col} = if buf, do: BufferAPI.cursor(buf), else: {0, 0}
    line_count = if buf, do: BufferAPI.line_count(buf), else: 1
    file_name = if buf, do: buf_display_name(buf), else: no_buffer_file_name
    dirty? = buf != nil and BufferAPI.dirty?(buf)
    filetype = if buf, do: buffer_filetype(buf), else: :text
    file_path = if buf, do: buffer_file_path(buf), else: nil

    {git_branch, git_diff_summary} = git_modeline_data(buf)
    git_degraded? = git_degraded?(file_path)
    diagnostic_counts = diagnostic_modeline_data_from_path(file_path)
    diagnostic_hint = cursor_line_diagnostic_hint_from_path(file_path, line)
    {minga_path, minga_here?} = minga_file(state, buf)

    mode = Minga.Editing.mode(state)
    mode_state = Editing.mode_state(state)
    {indent_type, indent_size} = indent_info(state, buf, filetype)
    selection_info = selection_info(mode, mode_state, buf, {line, col})

    agent = agent_state(state)
    agent_status = agent_session_status(state)
    background = background_subagent_summary(state)
    chrome_state = ChromeState.from_editor_state(state)
    workspace = workspace_modeline_summary(chrome_state)

    %Common{
      status: %SemanticStatusData{
        mode: mode,
        safe_mode?: Minga.SafeMode.active?(),
        dirty?: dirty?,
        cursor: %StatusCursor{line: line, col: col, line_count: line_count},
        diagnostics: %StatusDiagnostics{
          counts: diagnostic_counts || {0, 0, 0, 0},
          hint: diagnostic_hint
        },
        language: %StatusLanguage{
          lsp_status: state.lsp.status,
          parser_status: parser_status(state)
        },
        git: %StatusGit{branch: git_branch, diff_summary: git_diff_summary},
        file: %StatusFile{name: file_name, filetype: filetype},
        message: nil,
        recording: Minga.Editing.macro_recording_status(state),
        indent: %StatusIndent{type: indent_type, size: indent_size},
        selection: selection_model(selection_info),
        agent: %SemanticStatusAgent{
          agent_status: agent_status,
          background_count: background.count,
          background_label: background.label,
          active_tool_name: agent.runtime.active_tool_name
        },
        pending_keys: pending_keys(state, mode, mode_state)
      },
      raw_diagnostic_counts: diagnostic_counts,
      mode_state: mode_state,
      buf_index: state.workspace.buffers.active_index + 1,
      buf_count: Enum.count(state.workspace.buffers.list),
      notice: notice_message(state),
      selected_operation: OperationFeedback.selected(state.feedback.operation_feedback),
      agent_status_command: agent_status_command_content(state, agent),
      # Colors follow the status the modeline shows, which comes from the active
      # workspace, not only from the live cache.
      agent_theme_colors: if(agent_status, do: Theme.agent_theme(theme(state)), else: nil),
      git_degraded: git_degraded?,
      workspace: workspace,
      merge_conflict_count: merge_conflict_count(buf),
      plan_limit: plan_limit(state),
      needs_you_count: ChromeState.needs_you_count(chrome_state, agent_status),
      minga_progress: minga_progress(state),
      minga_file: minga_path,
      minga_here?: minga_here?,
      failed_language_servers: failed_language_servers(state),
      config_problem: config_problem(state),
      keymap_server: keymap_server(state),
      key_hints?: key_hints?(state)
    }
  end

  # The plan of the active workspace's Minga, read from the Editor's own projection.
  @spec minga_progress(EditorState.t() | map()) :: {non_neg_integer(), pos_integer()} | nil
  defp minga_progress(%{
         workspace: %{agent_ui: %UIState{view: %{activity: %Activity{} = activity}}}
       }),
       do: Activity.progress(activity)

  defp minga_progress(_state), do: nil

  # The file the connected task edited last, from the same projection, and whether it is the file the active buffer
  # visits. Both sides are file identities, so a symlinked or differently spelled path is still "here".
  @spec minga_file(EditorState.t() | map(), pid() | nil) :: {String.t() | nil, boolean()}
  defp minga_file(
         %{workspace: %{agent_ui: %UIState{view: %{activity: %Activity{} = activity}} = ui}},
         buf
       ) do
    case Activity.current_file(activity, Activity.task_author(UIState.task_id(ui))) do
      {identity, path} -> {path, is_pid(buf) and identity in Minga.Buffer.file_identities(buf)}
      nil -> {nil, false}
    end
  end

  defp minga_file(_state, _buf), do: {nil, false}

  @spec config_problem(EditorState.t() | map()) :: String.t() | nil
  defp config_problem(%{feedback: %{config_problem: problem}}), do: problem
  defp config_problem(_state), do: nil

  @spec failed_language_servers(EditorState.t() | map()) :: [String.t()]
  defp failed_language_servers(%{lsp: %{server_statuses: statuses}}) do
    for {name, :crashed} <- statuses, do: to_string(name)
  end

  defp failed_language_servers(_state), do: []

  # Clicks resolve through the same keymap the keys do, so a segment does what its key does.
  @spec keymap_server(EditorState.t() | map()) :: Minga.Keymap.server()
  defp keymap_server(%EditorState{interaction: %{keymap_server: server}}), do: server
  defp keymap_server(_state), do: Minga.Keymap.default_server()

  # CUA with the space leader turned off has no key for a leader binding, so segments name none.
  @spec key_hints?(EditorState.t() | map()) :: boolean()
  defp key_hints?(%EditorState{interaction: %{editing_model: :cua}}),
    do: Minga.Config.get(:space_leader) != :off

  defp key_hints?(_state), do: true

  # Reads only route usage the Editor already recorded from events; no registry call on render.
  @spec plan_limit(EditorState.t() | map()) :: MingaEditor.StatusBar.PlanLimit.t() | nil
  defp plan_limit(%EditorState{agent_connection: connection, workspace: workspace}) do
    RouteUsage.plan_limit(
      connection.route_usage,
      UIState.contributed_route_id(workspace.agent_ui),
      DateTime.utc_now(),
      &MingaAgent.InferenceRouteRegistry.local_time/1
    )
  end

  defp plan_limit(_state), do: nil

  @spec notice_message(EditorState.t() | map()) :: String.t() | nil
  defp notice_message(%{
         shell_runtime: %{state: %{notice: %Notice{message: message}}}
       }),
       do: message

  defp notice_message(%{shell_state: %{notice: %Notice{message: message}}}), do: message
  defp notice_message(_state), do: nil

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
  defp agent_state(%EditorState{shell_runtime: %{state: %TraditionalState{} = shell_state}}),
    do: TraditionalState.agent(shell_state)

  defp agent_state(%{shell_state: %TraditionalState{} = shell_state}),
    do: TraditionalState.agent(shell_state)

  defp agent_state(_state), do: %AgentState{}

  @spec agent_session(EditorState.t() | map()) :: pid() | nil
  defp agent_session(%EditorState{} = state),
    do: MingaEditor.Shell.Runtime.active_session(state.shell_runtime)

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
    BufferAPI.display_name(buf)
  catch
    :exit, _ -> "[no file]"
  end

  @spec buffer_filetype(pid()) :: atom()
  defp buffer_filetype(buf) do
    BufferAPI.filetype(buf) || :text
  catch
    :exit, _ -> :text
  end

  @spec buffer_file_path(pid()) :: String.t() | nil
  defp buffer_file_path(buf) do
    BufferAPI.file_path(buf)
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
    case BufferAPI.get_option(buf, option) do
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
  defp options_server(%EditorState{} = state), do: state.interaction.options_server
  defp options_server(%{options_server: server}), do: server
  defp options_server(_state), do: Options.default_server()

  @spec parser_status(EditorState.t() | map()) :: parser_status()
  defp parser_status(%EditorState{parser: %{parser_status: status}}), do: status
  defp parser_status(%{parser_status: status}), do: status

  @spec theme(EditorState.t() | map()) :: Theme.t()
  defp theme(%EditorState{appearance: %{theme: theme}}), do: theme
  defp theme(%{theme: theme}), do: theme

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
          BufferAPI.position()
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
    {:chars, BufferAPI.content_range_length(buf, anchor, cursor)}
  catch
    :exit, _ -> nil
  end

  defp selection_info(_mode, _mode_state, _buf, _cursor), do: nil

  @spec selection_model(selection_info()) :: StatusSelection.t()
  defp selection_model({:chars, count}), do: %StatusSelection{mode: :chars, size: count}
  defp selection_model({:lines, count}), do: %StatusSelection{mode: :lines, size: count}
  defp selection_model(nil), do: %StatusSelection{}

  # ── Agent variant ──────────────────────────────────────────────────────────

  # Every agent field comes from projections the Editor already holds; render
  # never asks the session process for anything, so a busy or stopped session
  # cannot stall the frame.
  @spec build_agent_data(EditorState.t() | map()) :: t()
  defp build_agent_data(state) do
    panel = state.workspace.agent_ui.panel

    %__MODULE__{
      common: state |> build_common_data("[no file]") |> apply_agent_modeline_theme(state),
      content: %StatusAgent{
        model_name: if(panel.model_name != "", do: panel.model_name, else: "Agent"),
        session_status: agent_session_status(state),
        message_count: UIState.TranscriptProjection.turn_count(panel.transcript)
      }
    }
  end

  # The status bar shows the same Agent status as the workspace pill and the
  # activity strip, named through the same token table.
  @spec agent_session_status(EditorState.t() | map()) :: WorkspaceStatus.t()
  defp agent_session_status(state) do
    state
    |> shell_state()
    |> WorkspaceStatus.active(state.workspace.agent_ui)
  end

  @spec shell_state(EditorState.t() | map()) :: term()
  defp shell_state(%EditorState{shell_runtime: %{state: shell_state}}), do: shell_state
  defp shell_state(%{shell_state: shell_state}), do: shell_state
  defp shell_state(_state), do: nil

  @spec apply_agent_modeline_theme(Common.t(), EditorState.t() | map()) :: Common.t()
  defp apply_agent_modeline_theme(%Common{} = common, state) do
    %{common | agent_theme_colors: Theme.agent_theme(theme(state))}
  end

  # A pending approval needs no text of its own: the status speaks as Needs you.
  @spec agent_status_command_content(EditorState.t() | map(), AgentState.t()) :: String.t() | nil
  defp agent_status_command_content(state, agent) do
    StatusCommand.content(agent_status_command_context(state, agent))
  end

  @spec agent_status_command_context(EditorState.t() | map(), AgentState.t()) ::
          StatusCommand.context()
  defp agent_status_command_context(state, agent) do
    agent_ui = state.workspace.agent_ui

    %{
      session_id: connected_session_id(agent_ui.connection, agent_session(state)),
      model: Panel.model_label(agent_ui.panel),
      status: agent.runtime.status,
      workdir: File.cwd!()
    }
  end

  # The cached connection names the session it describes. A connection left
  # over from a stopped or replaced session must not lend its id to the next one.
  @spec connected_session_id(ConnectionSnapshot.t() | nil, pid() | nil) :: String.t() | nil
  defp connected_session_id(
         %ConnectionSnapshot{target: %ConnectionTarget{session: session, session_id: id}},
         session
       )
       when is_pid(session),
       do: id

  defp connected_session_id(_connection, _session), do: nil

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

  Reads the repo's cached degradation flag (no git shell-out). Degraded means the
  last `git status` was trimmed (e.g. timed out on a huge full checkout), so the
  modeline shows a visible indicator rather than implying the status is complete.
  """
  @spec git_degraded?(String.t() | nil) :: boolean()
  def git_degraded?(nil), do: false

  def git_degraded?(path) when is_binary(path) do
    case GitRepo.cached_degraded_for_path(path) do
      {:ok, {degraded?, _reason}} -> degraded?
      :not_tracked -> false
    end
  end

  @spec merge_conflict_count(pid() | nil) :: non_neg_integer()
  defp merge_conflict_count(nil), do: 0

  defp merge_conflict_count(buf) when is_pid(buf) do
    BufferAPI.conflict_count(buf)
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
        BufferAPI.file_path(buf)
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
        BufferAPI.file_path(buf)
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
    |> Diagnostics.on_line(line)
    |> List.first()
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

  Both variants carry the same common fields and produce identical modeline data.
  """
  @spec to_modeline_data(t()) :: MingaEditor.Shell.Traditional.Modeline.modeline_data()
  def to_modeline_data(%__MODULE__{common: %Common{} = common}), do: data_to_modeline_data(common)

  @spec data_to_modeline_data(Common.t()) ::
          MingaEditor.Shell.Traditional.Modeline.modeline_data()
  defp data_to_modeline_data(%Common{status: %SemanticStatusData{} = status} = common) do
    workspace =
      common.workspace || %StatusWorkspace{id: 0, kind: :manual, label: "Files", icon: ""}

    selection_info = modeline_selection_info(status.selection)

    %{
      mode: status.mode,
      mode_state: common.mode_state,
      safe_mode: status.safe_mode?,
      file_name: status.file.name,
      filetype: status.file.filetype,
      dirty_marker: if(status.dirty?, do: " ● ", else: ""),
      cursor_line: status.cursor.line,
      cursor_col: status.cursor.col,
      line_count: status.cursor.line_count,
      buf_index: common.buf_index,
      buf_count: common.buf_count,
      macro_recording: status.recording,
      agent_status: status.agent.agent_status,
      active_tool_name: status.agent.active_tool_name,
      agent_status_command: common.agent_status_command,
      agent_theme_colors: common.agent_theme_colors,
      lsp_status: status.language.lsp_status,
      parser_status: status.language.parser_status,
      git_branch: status.git.branch,
      git_diff_summary: status.git.diff_summary,
      git_degraded: common.git_degraded,
      diagnostic_counts: common.raw_diagnostic_counts,
      indent_type: status.indent.type,
      indent_size: status.indent.size,
      selection_info: selection_info,
      background_subagent_count: status.agent.background_count,
      active_background_subagent_label: status.agent.background_label,
      workspace_label: workspace.label,
      workspace_draft_count: workspace.draft_count,
      workspace_conflict_count: workspace.conflict_count,
      merge_conflict_count: common.merge_conflict_count,
      plan_limit: common.plan_limit,
      needs_you_count: common.needs_you_count,
      minga_progress: common.minga_progress,
      minga_file: common.minga_file,
      minga_here?: common.minga_here?,
      change_position: common.change_position,
      failed_language_servers: common.failed_language_servers,
      config_problem: common.config_problem,
      keymap_server: common.keymap_server,
      key_hints?: common.key_hints?
    }
  end

  @spec modeline_selection_info(StatusSelection.t()) :: selection_info()
  defp modeline_selection_info(%StatusSelection{mode: :chars, size: count}), do: {:chars, count}
  defp modeline_selection_info(%StatusSelection{mode: :lines, size: count}), do: {:lines, count}
  defp modeline_selection_info(%StatusSelection{}), do: nil

  @spec workspace_modeline_summary(ChromeState.t()) :: StatusWorkspace.t() | nil
  defp workspace_modeline_summary(%ChromeState{} = chrome_state) do
    chrome_state.workspaces
    |> Enum.find(fn workspace -> workspace.id == chrome_state.active_workspace_id end)
    |> workspace_model(chrome_state)
  end

  @spec workspace_model(ChromeState.WorkspaceSummary.t() | nil, ChromeState.t()) ::
          StatusWorkspace.t() | nil
  defp workspace_model(nil, _chrome_state), do: nil

  defp workspace_model(%ChromeState.WorkspaceSummary{} = workspace, %ChromeState{} = chrome_state) do
    %StatusWorkspace{
      id: workspace.id,
      kind: workspace.kind,
      label: workspace.label,
      icon: workspace.icon,
      status: workspace.status,
      attention_count: chrome_state.attention_count,
      draft_count: chrome_state.draft_count,
      conflict_count: chrome_state.conflict_count,
      running_background_count: workspace.running_background_count,
      closeable?: workspace.closeable?,
      attention?: workspace.attention?
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
    tabs = Enum.filter(tb.tabs, &Tab.background_subagent?/1)
    running = Enum.filter(tabs, &background_subagent_running?/1)
    active = Enum.find(tabs, &(&1.id == tb.active_id))
    selected = active || List.first(running) || List.first(tabs)

    %{
      count: Enum.count(running),
      label: background_subagent_label(selected)
    }
  end

  defp background_subagent_summary(_state), do: %{count: 0, label: nil}

  defp background_subagent_label(%Tab{
         payload: %TabAgent{background_subagent: %MingaAgent.Subagent.Handle{} = handle}
       }) do
    MingaAgent.Subagent.Handle.label(handle)
  end

  defp background_subagent_label(_tab), do: nil

  @spec background_subagent_running?(Tab.t()) :: boolean()
  defp background_subagent_running?(%Tab{payload: %TabAgent{agent_status: status}}),
    do: status in [:thinking, :tool_executing]

  defp background_subagent_running?(%Tab{}), do: false
end
