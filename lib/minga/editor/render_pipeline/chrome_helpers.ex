defmodule Minga.Editor.RenderPipeline.ChromeHelpers do
  @moduledoc """
  Helper functions for the Chrome stage of the render pipeline.

  Renders modelines, tab bars, window separators, which-key popups,
  agent panels, and snapshot display names.

  Extracted from `RenderPipeline` to reduce module size.
  """

  alias Minga.Agent.ChatRenderer
  alias Minga.Agent.PanelState
  alias Minga.Agent.Session
  alias Minga.Editor.DisplayList
  alias Minga.Editor.Layout
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.Modeline
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.TabBarRenderer
  alias Minga.Editor.Viewport
  alias Minga.Editor.WindowTree
  alias Minga.Theme
  alias Minga.WhichKey

  @type state :: EditorState.t()

  @typep window_scroll :: Minga.Editor.RenderPipeline.WindowScroll.t()

  # ── Tab bar ────────────────────────────────────────────────────────────────

  @doc "Renders the tab bar, returning draws and click regions."
  @spec render_tab_bar(state(), Layout.t()) ::
          {[DisplayList.draw()], [TabBarRenderer.click_region()]}
  def render_tab_bar(%{tab_bar: nil}, _layout), do: {[], []}

  def render_tab_bar(state, layout) do
    {tab_row, _col, tab_width, _h} = layout.tab_bar
    TabBarRenderer.render(tab_row, tab_width, state.tab_bar, state.theme)
  end

  # ── Window modeline ────────────────────────────────────────────────────────

  @doc "Renders the modeline for a single window scroll result."
  @spec render_window_modeline(state(), window_scroll()) ::
          {[DisplayList.draw()], [Modeline.click_region()]}
  def render_window_modeline(state, %{win_layout: %{modeline: {_, _, _, 0}}}) do
    _ = state
    {[], []}
  end

  def render_window_modeline(state, scroll) do
    win_layout = scroll.win_layout
    is_active = scroll.is_active
    snapshot = scroll.snapshot
    cursor_line = scroll.cursor_line
    cursor_col = scroll.cursor_col

    {modeline_row, _mc, modeline_width, _mh} = win_layout.modeline
    {_row_off, col_off, _cw, _ch} = win_layout.content
    file_name = snapshot_display_name(snapshot)
    dirty_marker = if snapshot.dirty, do: " ● ", else: ""
    filetype = Map.get(snapshot, :filetype, :text)
    line_count = snapshot.line_count
    buf_count = length(state.buffers.list)
    buf_index = state.buffers.active_index + 1

    Modeline.render(
      modeline_row,
      modeline_width,
      %{
        mode: if(is_active, do: state.mode, else: :normal),
        mode_state: if(is_active, do: state.mode_state, else: nil),
        file_name: file_name,
        filetype: filetype,
        dirty_marker: dirty_marker,
        cursor_line: cursor_line,
        cursor_col: cursor_col,
        line_count: line_count,
        buf_index: buf_index,
        buf_count: buf_count,
        macro_recording:
          if(is_active, do: MacroRecorder.recording?(state.macro_recorder), else: false),
        agent_status: if(is_active, do: AgentAccess.agent(state).status, else: nil),
        agent_theme_colors:
          if(is_active && AgentAccess.agent(state).status,
            do: Theme.agent_theme(state.theme),
            else: nil
          )
      },
      state.theme,
      col_off
    )
  end

  # ── Separators ─────────────────────────────────────────────────────────────

  @doc "Renders vertical split separators between windows."
  @spec render_separators(WindowTree.t(), WindowTree.rect(), pos_integer(), Theme.t()) ::
          [DisplayList.draw()]
  def render_separators(tree, screen_rect, _total_rows, theme) do
    separators = collect_separators(tree, screen_rect)

    for {col, start_row, end_row} <- separators, row <- start_row..end_row do
      DisplayList.draw(row, col, "│", fg: theme.editor.split_border_fg)
    end
  end

  # ── Which-key ──────────────────────────────────────────────────────────────

  @doc "Renders the which-key popup overlay."
  @spec render_whichkey(state(), Viewport.t()) :: [DisplayList.draw()]
  def render_whichkey(%{whichkey: %{show: true, node: node}, theme: theme}, viewport)
      when is_map(node) do
    bindings = WhichKey.bindings_from_node(node)
    lines = WhichKey.render_popup(bindings)

    popup_row = max(0, viewport.rows - 3 - length(lines))

    border =
      DisplayList.draw(popup_row, 0, String.duplicate("─", viewport.cols),
        fg: theme.popup.border_fg
      )

    content_draws =
      lines
      |> Enum.with_index(popup_row + 1)
      |> Enum.map(fn {line_text, row} ->
        padded = String.pad_trailing(line_text, viewport.cols)
        DisplayList.draw(row, 0, padded, fg: theme.popup.fg, bg: theme.popup.bg)
      end)

    [border | content_draws]
  end

  def render_whichkey(_state, _viewport), do: []

  # ── Agent panel ────────────────────────────────────────────────────────────

  @doc "Renders the agent panel sidebar from the layout rect."
  @spec render_agent_panel_from_layout(state(), Layout.t()) :: [DisplayList.draw()]
  def render_agent_panel_from_layout(_state, %{agent_panel: nil}), do: []

  def render_agent_panel_from_layout(state, %{agent_panel: rect}) do
    agent = AgentAccess.agent(state)
    panel = AgentAccess.panel(state)
    session = AgentAccess.session(state)

    messages =
      if session do
        try do
          Session.messages(session)
        catch
          :exit, _ -> []
        end
      else
        []
      end

    usage =
      if session do
        try do
          Session.usage(session)
        catch
          :exit, _ -> %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}
        end
      else
        %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}
      end

    panel_state = %{
      messages: messages,
      status: agent.status || :idle,
      input_lines: PanelState.input_lines(panel),
      scroll: panel.scroll,
      spinner_frame: panel.spinner_frame,
      usage: usage,
      model_name: panel.model_name,
      thinking_level: panel.thinking_level,
      display_start_index: panel.display_start_index,
      error_message: agent.error,
      pending_approval: agent.pending_approval,
      mention_completion: panel.mention_completion
    }

    ChatRenderer.render(rect, panel_state, state.theme)
  end

  # ── Snapshot display name ──────────────────────────────────────────────────

  @doc "Returns a display name for a buffer snapshot (file name + RO marker)."
  @spec snapshot_display_name(map()) :: String.t()
  def snapshot_display_name(%{name: name} = snapshot) when is_binary(name) do
    ro = if Map.get(snapshot, :read_only, false), do: " [RO]", else: ""
    name <> ro
  end

  def snapshot_display_name(snapshot) do
    base =
      case snapshot.file_path do
        nil -> "[scratch]"
        path -> Path.basename(path)
      end

    ro = if Map.get(snapshot, :read_only, false), do: " [RO]", else: ""
    base <> ro
  end

  # ── Input cursor shape ────────────────────────────────────────────────────

  @doc "Returns the cursor shape for the agent panel input area."
  @spec input_cursor_shape(map()) :: Minga.Port.Protocol.cursor_shape()
  def input_cursor_shape(%PanelState{input_focused: true} = panel) do
    if PanelState.input_mode(panel) == :insert, do: :beam, else: :block
  end

  def input_cursor_shape(_panel), do: :block

  # ── Private helpers ────────────────────────────────────────────────────────

  @typep separator_span :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @spec collect_separators(WindowTree.t(), WindowTree.rect()) :: [separator_span()]
  defp collect_separators({:leaf, _}, _rect), do: []

  defp collect_separators(
         {:split, :vertical, left, right, size},
         {row, col, width, height}
       ) do
    usable = width - 1
    left_width = WindowTree.clamp_size(size, usable)
    right_width = max(usable - left_width, 1)
    separator_col = col + left_width

    [{separator_col, row, row + height - 1}] ++
      collect_separators(left, {row, col, left_width, height}) ++
      collect_separators(right, {row, separator_col + 1, right_width, height})
  end

  defp collect_separators(
         {:split, :horizontal, top, bottom, size},
         {row, col, width, height}
       ) do
    top_height = WindowTree.clamp_size(size, height)
    bottom_height = max(height - top_height, 1)

    collect_separators(top, {row, col, width, top_height}) ++
      collect_separators(bottom, {row + top_height, col, width, bottom_height})
  end
end
