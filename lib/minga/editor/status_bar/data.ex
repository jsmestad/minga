defmodule Minga.Editor.StatusBar.Data do
  @moduledoc """
  Tagged-union data struct for the global status bar.

  Computed once per frame from editor state and consumed by both rendering
  paths: `Chrome.TUI` feeds it to `Modeline.render/5` as cell draws;
  `Emit.GUI` encodes it as the 0x76 structured opcode for SwiftUI.

  The two variants reflect the two kinds of focused window content:
  - `{:buffer, t:buffer_data()}` — a normal buffer window
  - `{:agent, t:agent_data()}` — an agent chat window
  """

  alias Minga.Agent.Session
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Diagnostics
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.Window.Content
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Tracker, as: GitTracker
  alias Minga.LSP.SyncServer
  alias Minga.Theme

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Git diff summary: {added, modified, deleted} line counts."
  @type git_diff_summary :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil

  @typedoc "LSP connection status."
  @type lsp_status :: :ready | :initializing | :starting | :error | :none

  @typedoc "Parser availability status."
  @type parser_status :: :available | :unavailable | :restarting

  @typedoc "Data for a focused buffer window."
  @type buffer_data :: %{
          mode: Minga.Mode.mode(),
          mode_state: Minga.Mode.state() | nil,
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer(),
          line_count: non_neg_integer(),
          file_name: String.t(),
          filetype: atom(),
          dirty: boolean(),
          git_branch: String.t() | nil,
          git_diff_summary: git_diff_summary(),
          diagnostic_counts:
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil,
          diagnostic_hint: String.t() | nil,
          lsp_status: lsp_status(),
          parser_status: parser_status(),
          buf_index: pos_integer(),
          buf_count: non_neg_integer(),
          macro_recording: {true, String.t()} | false,
          agent_status: AgentState.status(),
          agent_theme_colors: Theme.Agent.t() | nil,
          status_msg: String.t() | nil
        }

  @typedoc "Data for a focused agent chat window. Includes background buffer context so the status bar layout stays stable across mode switches."
  @type agent_data :: %{
          mode: Minga.Mode.mode(),
          mode_state: Minga.Mode.state() | nil,
          model_name: String.t(),
          session_status: AgentState.status(),
          message_count: non_neg_integer(),
          macro_recording: {true, String.t()} | false,
          agent_status: AgentState.status(),
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
          diagnostic_counts:
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil,
          diagnostic_hint: String.t() | nil,
          lsp_status: lsp_status(),
          parser_status: parser_status(),
          buf_index: pos_integer(),
          buf_count: non_neg_integer(),
          status_msg: String.t() | nil
        }

  @typedoc "Tagged union: buffer or agent variant."
  @type t :: {:buffer, buffer_data()} | {:agent, agent_data()}

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Builds the status bar data from the current editor state.

  Inspects the active window's content type and returns the appropriate
  tagged variant. Called once per render frame before the Chrome stage.
  """
  @spec from_state(EditorState.t()) :: t()
  def from_state(state) do
    active_window = Map.get(state.workspace.windows.map, state.workspace.windows.active)

    if active_window != nil and Content.agent_chat?(active_window.content) do
      {:agent, build_agent_data(state)}
    else
      {:buffer, build_buffer_data(state)}
    end
  end

  # ── Buffer variant ─────────────────────────────────────────────────────────

  @spec build_buffer_data(EditorState.t()) :: buffer_data()
  defp build_buffer_data(state) do
    buf = state.workspace.buffers.active
    {line, col} = if buf, do: BufferServer.cursor(buf), else: {0, 0}
    line_count = if buf, do: BufferServer.line_count(buf), else: 1
    file_name = if buf, do: buf_display_name(buf), else: "[no file]"
    dirty = buf != nil and BufferServer.dirty?(buf)
    filetype = if buf, do: buffer_filetype(buf), else: :text

    {git_branch, git_diff_summary} = git_modeline_data(buf)
    diagnostic_counts = diagnostic_modeline_data(buf)

    # Fetch diagnostic hint for the current cursor line (shown in status bar
    # center segment when idle, replaces the old cell-grid minibuffer hint)
    diagnostic_hint = cursor_line_diagnostic_hint(buf, line)

    agent = AgentAccess.agent(state)

    %{
      mode: state.workspace.vim.mode,
      mode_state: state.workspace.vim.mode_state,
      cursor_line: line,
      cursor_col: col,
      line_count: line_count,
      file_name: file_name,
      filetype: filetype,
      dirty: dirty,
      git_branch: git_branch,
      git_diff_summary: git_diff_summary,
      diagnostic_counts: diagnostic_counts,
      diagnostic_hint: diagnostic_hint,
      lsp_status: state.lsp_status,
      parser_status: state.parser_status,
      buf_index: state.workspace.buffers.active_index + 1,
      buf_count: length(state.workspace.buffers.list),
      macro_recording: MacroRecorder.recording?(state.workspace.vim.macro_recorder),
      agent_status: agent.status,
      agent_theme_colors: if(agent.status, do: Theme.agent_theme(state.theme), else: nil),
      status_msg: state.status_msg
    }
  end

  @spec buf_display_name(pid()) :: String.t()
  defp buf_display_name(buf) do
    BufferServer.display_name(buf)
  catch
    :exit, _ -> "[no file]"
  end

  @spec buffer_filetype(pid()) :: atom()
  defp buffer_filetype(buf) do
    BufferServer.filetype(buf) || :text
  catch
    :exit, _ -> :text
  end

  # ── Agent variant ──────────────────────────────────────────────────────────

  @spec build_agent_data(EditorState.t()) :: agent_data()
  defp build_agent_data(state) do
    agent = AgentAccess.agent(state)
    panel = AgentAccess.panel(state)

    message_count =
      if agent.session do
        try do
          length(Session.messages(agent.session))
        catch
          :exit, _ -> 0
        end
      else
        0
      end

    model_name = if panel.model_name != "", do: panel.model_name, else: "Agent"

    # Pull background buffer context so the status bar stays stable
    buf = state.workspace.buffers.active
    {line, col} = if buf, do: BufferServer.cursor(buf), else: {0, 0}
    line_count = if buf, do: BufferServer.line_count(buf), else: 1
    file_name = if buf, do: buf_display_name(buf), else: "[no file]"
    dirty = buf != nil and BufferServer.dirty?(buf)
    filetype = if buf, do: buffer_filetype(buf), else: :text

    {git_branch, git_diff_summary} = git_modeline_data(buf)
    diagnostic_counts = diagnostic_modeline_data(buf)
    diagnostic_hint = cursor_line_diagnostic_hint(buf, line)

    %{
      mode: state.workspace.vim.mode,
      mode_state: state.workspace.vim.mode_state,
      model_name: model_name,
      session_status: agent.status,
      message_count: message_count,
      macro_recording: MacroRecorder.recording?(state.workspace.vim.macro_recorder),
      agent_status: agent.status,
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
      diagnostic_counts: diagnostic_counts,
      diagnostic_hint: diagnostic_hint,
      lsp_status: state.lsp_status,
      parser_status: state.parser_status,
      buf_index: state.workspace.buffers.active_index + 1,
      buf_count: length(state.workspace.buffers.list),
      status_msg: state.status_msg
    }
  end

  # ── Git helpers ────────────────────────────────────────────────────────────

  @doc "Returns {branch_name | nil, diff_summary | nil} for the status bar."
  @spec git_modeline_data(pid() | nil) :: {String.t() | nil, git_diff_summary()}
  def git_modeline_data(nil), do: {nil, nil}

  def git_modeline_data(buf) when is_pid(buf) do
    case GitTracker.lookup(buf) do
      nil ->
        {nil, nil}

      git_pid ->
        try do
          GitBuffer.modeline_info(git_pid)
        catch
          :exit, _ -> {nil, nil}
        end
    end
  end

  @doc "Returns the diagnostic count 4-tuple for the active buffer, or nil."
  @spec diagnostic_modeline_data(pid() | nil) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  def diagnostic_modeline_data(nil), do: nil

  def diagnostic_modeline_data(buf) when is_pid(buf) do
    path =
      try do
        BufferServer.file_path(buf)
      catch
        :exit, _ -> nil
      end

    case path do
      nil -> nil
      path -> Diagnostics.count_tuple(SyncServer.path_to_uri(path))
    end
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
        BufferServer.file_path(buf)
      catch
        :exit, _ -> nil
      end

    case file_path do
      nil ->
        nil

      path ->
        uri = SyncServer.path_to_uri(path)

        uri
        |> Diagnostics.for_uri()
        |> Enum.find(fn d -> d.range.start_line == line end)
        |> format_diagnostic_hint()
    end
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
  @spec to_modeline_data(t()) :: Minga.Editor.Modeline.modeline_data()
  def to_modeline_data({_variant, d}) do
    %{
      mode: d.mode,
      mode_state: d.mode_state,
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
      agent_theme_colors: d.agent_theme_colors,
      lsp_status: d.lsp_status,
      parser_status: d.parser_status,
      git_branch: d.git_branch,
      git_diff_summary: d.git_diff_summary,
      diagnostic_counts: d.diagnostic_counts
    }
  end
end
