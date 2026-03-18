defmodule Minga.Editor.RenderPipeline.ChromeHelpers do
  @moduledoc """
  Helper functions for the Chrome stage of the render pipeline.

  Renders modelines, tab bars, window separators, which-key popups,
  and snapshot display names.

  Extracted from `RenderPipeline` to reduce module size.
  """

  alias Minga.Agent.Session
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options
  alias Minga.Diagnostics
  alias Minga.Editor.DisplayList
  alias Minga.Editor.FloatingWindow
  alias Minga.Editor.Layout
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.Modeline
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.TabBarRenderer
  alias Minga.Editor.Viewport
  alias Minga.Editor.WindowTree
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Tracker, as: GitTracker
  alias Minga.LSP.SyncServer
  alias Minga.Theme
  alias Minga.WhichKey
  alias Minga.Face

  @type state :: EditorState.t()

  @typep window_scroll :: Minga.Editor.RenderPipeline.Scroll.WindowScroll.t()

  # ── Tab bar ────────────────────────────────────────────────────────────────

  @doc "Renders the tab bar, returning draws and click regions."
  @spec render_tab_bar(state(), Layout.t()) ::
          {[DisplayList.draw()], [TabBarRenderer.click_region()]}
  def render_tab_bar(%{tab_bar: nil}, _layout), do: {[], []}
  def render_tab_bar(_state, %{tab_bar: nil}), do: {[], []}

  def render_tab_bar(state, layout) do
    {tab_row, _col, tab_width, _h} = layout.tab_bar

    hover_col =
      case state.mouse.hover_pos do
        {^tab_row, col} -> col
        _ -> nil
      end

    TabBarRenderer.render(tab_row, tab_width, state.tab_bar, state.theme, hover_col)
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

    lsp_status = if is_active, do: state.lsp_status, else: :none

    buf = scroll.window.buffer
    {git_branch, git_diff_summary} = git_modeline_data(buf)
    diagnostic_counts = diagnostic_modeline_data(buf)

    Modeline.render(
      modeline_row,
      modeline_width,
      %{
        mode: if(is_active, do: state.vim.mode, else: :normal),
        mode_state: if(is_active, do: state.vim.mode_state, else: nil),
        file_name: file_name,
        filetype: filetype,
        dirty_marker: dirty_marker,
        cursor_line: cursor_line,
        cursor_col: cursor_col,
        line_count: line_count,
        buf_index: buf_index,
        buf_count: buf_count,
        macro_recording:
          if(is_active, do: MacroRecorder.recording?(state.vim.macro_recorder), else: false),
        agent_status: if(is_active, do: AgentAccess.agent(state).status, else: nil),
        agent_theme_colors:
          if(is_active && AgentAccess.agent(state).status,
            do: Theme.agent_theme(state.theme),
            else: nil
          ),
        lsp_status: lsp_status,
        parser_status: state.parser_status,
        git_branch: git_branch,
        git_diff_summary: git_diff_summary,
        diagnostic_counts: diagnostic_counts
      },
      state.theme,
      col_off
    )
  end

  @doc """
  Renders the modeline for an agent chat window.

  Shows vim mode, macro recording, and agent session status instead of
  the filename/filetype/position info that buffer modelines display.
  """
  @spec render_agent_modeline(state(), Layout.window_layout()) ::
          {[DisplayList.draw()], [Modeline.click_region()]}
  def render_agent_modeline(state, win_layout) do
    {modeline_row, _mc, modeline_width, modeline_height} = win_layout.modeline

    if modeline_height == 0 do
      {[], []}
    else
      {_row_off, col_off, _cw, _ch} = win_layout.content
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

      model_label =
        if panel.model_name != "", do: panel.model_name, else: "Agent"

      Modeline.render(
        modeline_row,
        modeline_width,
        %{
          mode: state.vim.mode,
          mode_state: state.vim.mode_state,
          file_name: "󰚩 #{model_label}",
          filetype: :text,
          dirty_marker: "",
          cursor_line: message_count,
          cursor_col: 0,
          line_count: max(message_count, 1),
          buf_index: 1,
          buf_count: 1,
          macro_recording: MacroRecorder.recording?(state.vim.macro_recorder),
          agent_status: agent.status,
          agent_theme_colors: Theme.agent_theme(state.theme),
          mode_override: nil
        },
        state.theme,
        col_off
      )
    end
  end

  # ── Separators ─────────────────────────────────────────────────────────────

  @doc "Renders vertical split separators between windows."
  @spec render_separators(WindowTree.t(), WindowTree.rect(), pos_integer(), Theme.t()) ::
          [DisplayList.draw()]
  def render_separators(tree, screen_rect, _total_rows, theme) do
    separators = collect_separators(tree, screen_rect)

    for {col, start_row, end_row} <- separators, row <- start_row..end_row do
      DisplayList.draw(row, col, "│", Face.new(fg: theme.editor.split_border_fg))
    end
  end

  # ── Which-key ──────────────────────────────────────────────────────────────

  @doc "Renders the which-key popup overlay."
  @spec render_whichkey(state(), Viewport.t(), :bottom | :float) :: [DisplayList.draw()]
  def render_whichkey(state, viewport, layout \\ Options.get(:whichkey_layout))

  def render_whichkey(%{whichkey: %{show: true, node: node} = wk, theme: theme}, viewport, layout)
      when is_map(node) do
    bindings = WhichKey.bindings_from_node(node)
    prefix_title = whichkey_prefix_title(wk)
    page = Map.get(wk, :page, 0)

    case layout do
      :float -> render_whichkey_float(bindings, prefix_title, page, theme, viewport)
      _bottom -> render_whichkey_bottom(bindings, prefix_title, page, theme, viewport)
    end
  end

  def render_whichkey(_state, _viewport, _layout), do: []

  # Builds the prefix path title (e.g. "SPC f") from accumulated keys.
  @spec whichkey_prefix_title(map()) :: String.t()
  defp whichkey_prefix_title(%{prefix_keys: keys}) when is_list(keys) and keys != [] do
    Enum.join(keys, " ")
  end

  defp whichkey_prefix_title(_), do: "Which Key"

  # Computes multi-column layout for which-key bindings.
  # Returns {column_count, rows_per_page, grid} where grid is a list of rows,
  # each row is a list of bindings (or nil for empty cells).
  @spec whichkey_column_layout([WhichKey.Binding.t()], integer()) ::
          {pos_integer(), [[WhichKey.Binding.t() | nil]]}
  defp whichkey_column_layout(bindings, available_width) do
    # When any binding has an icon, all entries reserve 2 chars for the icon
    # column so keys stay aligned. Include that in the width calculation.
    has_icons = Enum.any?(bindings, fn %WhichKey.Binding{icon: icon} -> icon != nil end)
    icon_w = if has_icons, do: 2, else: 0

    entry_width = fn %WhichKey.Binding{key: key, description: desc} ->
      icon_w + String.length(key) + 3 + String.length(desc)
    end

    max_entry_w = bindings |> Enum.map(entry_width) |> Enum.max(fn -> 20 end)
    col_width = max_entry_w + 2
    num_cols = max(div(available_width, col_width), 1) |> min(3)

    num_rows = ceil(length(bindings) / num_cols)

    # Fill columns left-to-right, then top-to-bottom (Doom order).
    grid =
      for row <- 0..(num_rows - 1) do
        for col <- 0..(num_cols - 1) do
          idx = col * num_rows + row
          Enum.at(bindings, idx)
        end
      end

    {num_cols, grid}
  end

  # Renders a single binding entry as a list of styled draws at the given position.
  # When `has_icons` is true, all entries reserve 2 chars for the icon column so
  # keys and descriptions stay aligned even when some entries lack an icon.
  @spec render_whichkey_entry(
          WhichKey.Binding.t(),
          non_neg_integer(),
          non_neg_integer(),
          Theme.Popup.t(),
          boolean()
        ) ::
          [DisplayList.draw()]
  defp render_whichkey_entry(%WhichKey.Binding{} = binding, row, col, popup, has_icons) do
    key_fg = Map.get(popup, :key_fg) || popup.fg
    sep_fg = Map.get(popup, :separator_fg) || popup.fg
    desc_fg = whichkey_desc_fg(binding.kind, popup)
    bg = popup.bg

    draws = []
    cur_col = col

    # Icon column: when any entry in the grid has an icon, reserve 2 chars
    # for every entry so keys stay aligned.
    {draws, cur_col} =
      if binding.icon do
        icon_draw = DisplayList.draw(row, cur_col, binding.icon, Face.new(fg: desc_fg, bg: bg))
        {[icon_draw | draws], cur_col + 2}
      else
        if has_icons do
          {draws, cur_col + 2}
        else
          {draws, cur_col}
        end
      end

    # Key
    key_draw = DisplayList.draw(row, cur_col, binding.key, Face.new(fg: key_fg, bg: bg))
    cur_col = cur_col + String.length(binding.key)

    # Separator
    sep_draw = DisplayList.draw(row, cur_col, " : ", Face.new(fg: sep_fg, bg: bg))
    cur_col = cur_col + 3

    # Description
    desc_draw = DisplayList.draw(row, cur_col, binding.description, Face.new(fg: desc_fg, bg: bg))

    Enum.reverse([desc_draw, sep_draw, key_draw | draws])
  end

  @spec whichkey_desc_fg(:command | :group, Theme.Popup.t()) :: Theme.color()
  defp whichkey_desc_fg(:group, popup), do: Map.get(popup, :group_fg) || popup.fg
  defp whichkey_desc_fg(:command, popup), do: popup.fg

  @spec render_whichkey_bottom(
          [WhichKey.Binding.t()],
          String.t(),
          non_neg_integer(),
          Theme.t(),
          Viewport.t()
        ) :: [DisplayList.draw()]
  defp render_whichkey_bottom(bindings, prefix_title, page, theme, viewport) do
    popup = theme.popup
    # Available interior width (border + padding on each side)
    interior_w = viewport.cols - 4

    {_num_cols, grid} = whichkey_column_layout(bindings, interior_w)

    col_width =
      if interior_w > 0,
        do: max(div(interior_w, max(length(List.first(grid, [])), 1)), 20),
        else: 20

    total_rows = length(grid)
    # Max rows that fit: viewport height minus modeline(1) + minibuffer(1) + border(2) + title row
    max_content_rows = max(viewport.rows - 5, 3)
    total_pages = max(ceil(total_rows / max_content_rows), 1)
    safe_page = min(page, total_pages - 1)
    page_start = safe_page * max_content_rows
    visible_grid = Enum.slice(grid, page_start, max_content_rows)
    visible_rows = length(visible_grid)

    # FloatingWindow dimensions: content + border
    float_h = visible_rows + 2
    float_w = viewport.cols

    # Position at bottom, above modeline + minibuffer
    float_row = max(viewport.rows - 2 - float_h, 0)

    footer =
      if total_pages > 1, do: "#{safe_page + 1} of #{total_pages}", else: nil

    content_draws = whichkey_grid_draws(visible_grid, col_width, popup)
    popup_theme = whichkey_popup_theme(popup)

    spec = %FloatingWindow.Spec{
      title: prefix_title,
      footer: footer,
      content: content_draws,
      width: {:cols, float_w},
      height: {:rows, float_h},
      position:
        {float_row - div(viewport.rows - float_h, 2), 0 - div(viewport.cols - float_w, 2)},
      border: :rounded,
      theme: popup_theme,
      viewport: {viewport.rows, viewport.cols}
    }

    FloatingWindow.render(spec)
  end

  @spec render_whichkey_float(
          [WhichKey.Binding.t()],
          String.t(),
          non_neg_integer(),
          Theme.t(),
          Viewport.t()
        ) :: [DisplayList.draw()]
  defp render_whichkey_float(bindings, prefix_title, page, theme, viewport) do
    popup = theme.popup
    popup_theme = whichkey_popup_theme(popup)

    # Available interior width (70% of terminal minus border/padding)
    float_w = min(div(viewport.cols * 70, 100), viewport.cols)
    interior_w = float_w - 4

    {_num_cols, grid} = whichkey_column_layout(bindings, interior_w)

    col_width =
      if interior_w > 0,
        do: max(div(interior_w, max(length(List.first(grid, [])), 1)), 20),
        else: 20

    total_rows = length(grid)
    max_content_rows = max(div(viewport.rows * 60, 100), 3)
    total_pages = max(ceil(total_rows / max_content_rows), 1)
    safe_page = min(page, total_pages - 1)
    page_start = safe_page * max_content_rows
    visible_grid = Enum.slice(grid, page_start, max_content_rows)
    visible_rows = length(visible_grid)

    float_h = visible_rows + 2

    footer =
      if total_pages > 1, do: "#{safe_page + 1} of #{total_pages}", else: nil

    content_draws = whichkey_grid_draws(visible_grid, col_width, popup)

    spec = %FloatingWindow.Spec{
      title: prefix_title,
      footer: footer,
      content: content_draws,
      width: {:cols, float_w},
      height: {:rows, float_h},
      border: :rounded,
      theme: popup_theme,
      viewport: {viewport.rows, viewport.cols}
    }

    FloatingWindow.render(spec)
  end

  # Converts a paginated grid of bindings into a flat list of styled draws.
  @spec whichkey_grid_draws([[WhichKey.Binding.t() | nil]], non_neg_integer(), Theme.Popup.t()) ::
          [DisplayList.draw()]
  defp whichkey_grid_draws(visible_grid, col_width, popup) do
    has_icons =
      Enum.any?(visible_grid, fn row ->
        Enum.any?(row, fn
          nil -> false
          %WhichKey.Binding{icon: icon} -> icon != nil
        end)
      end)

    Enum.flat_map(Enum.with_index(visible_grid), fn {row_entries, row_idx} ->
      Enum.flat_map(Enum.with_index(row_entries), fn
        {nil, _col_idx} ->
          []

        {entry, col_idx} ->
          render_whichkey_entry(entry, row_idx, col_idx * col_width, popup, has_icons)
      end)
    end)
  end

  @spec whichkey_popup_theme(Theme.Popup.t()) :: map()
  defp whichkey_popup_theme(popup) do
    %{
      fg: popup.fg,
      bg: popup.bg,
      border_fg: popup.border_fg,
      title_fg: Map.get(popup, :title_fg, popup.border_fg)
    }
  end

  # ── Agent panel ────────────────────────────────────────────────────────────

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
        nil -> "[no file]"
        path -> Path.basename(path)
      end

    ro = if Map.get(snapshot, :read_only, false), do: " [RO]", else: ""
    base <> ro
  end

  # ── Input cursor shape ────────────────────────────────────────────────────

  @doc "Returns the cursor shape for the agent panel input area."
  @spec input_cursor_shape(atom()) :: Minga.Port.Protocol.cursor_shape()
  def input_cursor_shape(:insert), do: :beam
  def input_cursor_shape(_mode), do: :block

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

  # ── Git modeline data ─────────────────────────────────────────────────────

  # Returns {branch_name | nil, {added, modified, deleted} | nil} for the
  # modeline. Single GenServer call to Git.Buffer, no file I/O: the branch
  # is cached on Git.Buffer state and refreshed on init and save.
  @spec git_modeline_data(pid() | nil) :: {String.t() | nil, GitBuffer.diff_summary() | nil}
  defp git_modeline_data(nil), do: {nil, nil}

  defp git_modeline_data(buf) when is_pid(buf) do
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

  @spec diagnostic_modeline_data(pid() | nil) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  defp diagnostic_modeline_data(nil), do: nil

  defp diagnostic_modeline_data(buf) when is_pid(buf) do
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
end
