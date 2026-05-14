defmodule MingaEditor.Shell.Traditional.TreeRenderer do
  @moduledoc """
  Renders the file tree panel into draw tuples for the left side of the screen.

  Produces a list of `DisplayList.draw()` tuples for the tree entries,
  the separator column, and the header line. Uses Nerd Font icons per
  filetype, box-drawing indent guides, and a project-name header to
  match neo-tree.nvim's visual style.
  """

  alias Minga.Core.Face
  alias Minga.Language
  alias Minga.Project.FileTree
  alias MingaEditor.DisplayList
  alias MingaEditor.FileTree.Row
  alias MingaEditor.FileTree.Rows
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.UI.Devicon
  alias MingaEditor.UI.Theme
  alias MingaEditor.WindowTree

  # Box-drawing characters for indent guides
  @guide_pipe "│ "
  @guide_tee "├─"
  @guide_elbow "└─"
  @guide_blank "  "

  # Nerd Font folder icons (nf-md-folder / nf-md-folder-open)
  @folder_closed "\u{F024B}"
  @folder_open "\u{F0256}"

  defmodule RenderInput do
    @moduledoc """
    Input struct for TreeRenderer.render/1.
    Contains only the data needed to render the tree panel.
    """
    @enforce_keys [:tree, :rect, :focused, :theme, :active_path]
    defstruct [
      :tree,
      :rect,
      :focused,
      :theme,
      :active_path,
      editing: nil,
      git_status: %{},
      dirty_paths: MapSet.new(),
      rows: nil
    ]

    @type t :: %__MODULE__{
            tree: FileTree.t(),
            rect: WindowTree.rect(),
            focused: boolean(),
            theme: Theme.t(),
            active_path: String.t() | nil,
            editing: FileTreeState.editing() | nil,
            git_status: Minga.Project.FileTree.GitStatus.status_map(),
            dirty_paths: MapSet.t(String.t()),
            rows: [Row.t()] | nil
          }
  end

  @doc """
  Renders the file tree panel.

  Accepts either a `RenderInput` struct containing focused rendering data,
  or an `EditorState` (which extracts the necessary data and delegates).

  Returns a list of `DisplayList.draw()` tuples for the tree content,
  separator, and header.
  """
  @spec render(RenderInput.t()) :: [DisplayList.draw()]
  def render(%RenderInput{} = input) do
    rows =
      input.rows ||
        Rows.from_tree(input.tree,
          active_path: input.active_path,
          dirty_paths: input.dirty_paths,
          editing: input.editing,
          focused: input.focused,
          git_status: input.git_status
        )

    do_render(input.tree, input.rect, input.theme, rows)
  end

  @spec render(EditorState.t() | map()) :: [DisplayList.draw()]
  def render(%EditorState{workspace: %{file_tree: %{tree: nil}}}), do: []
  def render(%{workspace: %{file_tree: %{tree: nil}}}), do: []

  def render(%EditorState{} = state) do
    render_from_workspace(state.workspace, state.theme, state)
  end

  def render(%{workspace: %{file_tree: %{tree: _tree}}} = state) do
    render_from_workspace(state.workspace, state.theme, state)
  end

  def render(_state), do: []

  @spec render_from_workspace(map(), MingaEditor.UI.Theme.t(), map()) :: [DisplayList.draw()]
  defp render_from_workspace(
         %{file_tree: %{tree: tree, focused: focused}} = _ws,
         _theme,
         state
       ) do
    rect = tree_rect_from_workspace(state.workspace)

    input = %RenderInput{
      tree: tree,
      rect: rect,
      focused: focused,
      theme: state.theme,
      active_path: nil,
      rows: Rows.from_state(state)
    }

    render(input)
  end

  @spec do_render(FileTree.t(), WindowTree.rect(), Theme.t(), [Row.t()]) :: [DisplayList.draw()]
  defp do_render(tree, {row_off, col_off, width, height}, theme, rows) do
    # Header: project directory name with folder icon
    project_name = Path.basename(tree.root)
    header_text = " #{@folder_open} #{project_name}/"
    header_display = String.slice(header_text, 0, width) |> String.pad_trailing(width)

    header = [
      DisplayList.draw(
        row_off,
        col_off,
        header_display,
        Face.new(fg: theme.tree.header_fg, bg: theme.tree.header_bg, bold: true)
      )
    ]

    # Entry rows (starting from row 1, leaving row 0 for header)
    content_rows = height - 1
    scroll_offset = scroll_offset(selected_index(rows), content_rows)

    render_opts = %{
      col_off: col_off,
      width: width,
      theme: theme
    }

    entry_commands =
      rows
      |> Enum.drop(scroll_offset)
      |> Enum.take(content_rows)
      |> Enum.with_index()
      |> Enum.flat_map(fn {tree_row, screen_row} ->
        row = row_off + 1 + screen_row

        if tree_row.editing != nil do
          render_editing_entry(tree_row, row, render_opts)
        else
          render_entry(tree_row, row, render_opts)
        end
      end)

    # Fill remaining rows with blanks
    visible_count = rows |> Enum.drop(scroll_offset) |> Enum.take(content_rows) |> length()

    blank_commands =
      render_blanks(visible_count, content_rows, row_off + 1, col_off, width, theme)

    # Separator column (one column right of the tree area)
    sep_col = col_off + width
    sep_commands = render_separator(sep_col, row_off, height, theme)

    header ++ entry_commands ++ blank_commands ++ sep_commands
  end

  # ── Entry rendering ──────────────────────────────────────────────────────

  @spec render_entry(Row.t(), non_neg_integer(), map()) :: [DisplayList.draw()]
  defp render_entry(tree_row, row, opts) do
    %{col_off: col, width: width, theme: theme} = opts

    is_cursor = tree_row.selected?
    focused = tree_row.focused?
    is_dirty = tree_row.dirty?

    # Build the guide prefix from the entry's ancestor guide flags
    guide_prefix = build_guides(tree_row.guides, tree_row.last_child?)

    # Pick the icon and its color
    {icon, icon_color} = entry_icon(tree_row)

    # Entry name (dirs get trailing slash)
    name = if tree_row.directory?, do: tree_row.name <> "/", else: tree_row.name

    # Right-side indicators: [modified_dot] [git_status]
    # Modified dot = 1 col, git status = 2 cols (space + symbol)
    file_git_status = tree_row.git_status
    git_width = if file_git_status, do: 2, else: 0
    dirty_width = if is_dirty, do: 1, else: 0
    indicator_width = dirty_width + git_width

    # Compose the full line: guides + icon + space + name
    prefix = guide_prefix <> icon <> " "
    prefix_width = String.length(prefix)

    # Truncate name to fit, accounting for indicator space
    max_name_len = max(width - prefix_width - indicator_width, 0)
    display_name = String.slice(name, 0, max_name_len)

    # Background style for the full row
    row_bg = row_background(is_cursor, focused, theme)

    # Build draw commands: guide, icon, name, (dirty dot), (git indicator)
    guide_style = guide_draw_style(is_cursor, focused, theme)
    icon_style = icon_draw_style(icon_color, is_cursor, focused, theme)
    name_style = name_draw_style(tree_row, is_cursor, tree_row.active?, focused, theme)

    guide_len = String.length(guide_prefix)

    draws = []

    # Guide segment (if any depth > 0)
    draws =
      if guide_len > 0 do
        draws ++ [DisplayList.draw(row, col, guide_prefix, guide_style)]
      else
        draws
      end

    # Icon segment
    icon_col = col + guide_len
    draws = draws ++ [DisplayList.draw(row, icon_col, icon <> " ", icon_style)]

    # Name segment: pad to fill space between name and indicators
    name_col = col + prefix_width
    name_pad_width = max(width - prefix_width - indicator_width, 0)
    padded_name = String.pad_trailing(display_name, name_pad_width)
    draws = draws ++ [DisplayList.draw(row, name_col, padded_name, name_style)]

    # Right-aligned indicators start here
    indicator_col = col + width - indicator_width

    # Modified buffer dot (between name and git status)
    draws =
      if is_dirty do
        dirty_style = dirty_indicator_style(is_cursor, focused, theme)
        draws ++ [DisplayList.draw(row, indicator_col, "●", dirty_style)]
      else
        draws
      end

    # Git status indicator (rightmost)
    if file_git_status do
      git_col = col + width - git_width
      git_symbol = " " <> Minga.Project.FileTree.GitStatus.symbol(file_git_status)
      git_style = git_indicator_style(file_git_status, is_cursor, focused, theme)
      draws ++ [DisplayList.draw(row, git_col, git_symbol, git_style)]
    else
      # Pad remaining space if no indicators
      drawn_width = prefix_width + String.length(padded_name) + dirty_width

      if drawn_width < width do
        pad = String.duplicate(" ", width - drawn_width)
        pad_face = %{row_bg | fg: theme.tree.fg}
        draws ++ [DisplayList.draw(row, col + drawn_width, pad, pad_face)]
      else
        draws
      end
    end
  end

  # ── Editing entry rendering ─────────────────────────────────────────────

  # Renders the inline editing entry with highlighted styling and a cursor indicator.
  # The editing row shows the entry's indent guides, a type indicator icon, the
  # current editing text, and a block cursor at the insertion point.
  @spec render_editing_entry(Row.t(), non_neg_integer(), map()) :: [DisplayList.draw()]
  defp render_editing_entry(tree_row, row, opts) do
    %{col_off: col, width: width, theme: theme} = opts
    editing = tree_row.editing

    # Build indent guides (same depth as the entry being edited/created)
    guide_prefix = build_guides(tree_row.guides, tree_row.last_child?)
    guide_len = String.length(guide_prefix)

    # Type indicator: file icon for new file, folder icon for new folder,
    # the entry's own icon for rename
    {icon, _icon_color} =
      case editing.type do
        :new_file -> {"", 0x519ABA}
        :new_folder -> {@folder_open, 0x519ABA}
        :rename -> entry_icon(tree_row)
      end

    prefix = guide_prefix <> icon <> " "
    prefix_len = String.length(prefix)

    # Editing text with cursor
    text = editing.text
    cursor_char = "▏"
    display_text = text <> cursor_char

    # Truncate to fit
    max_text_len = max(width - prefix_len, 0)
    display_text = String.slice(display_text, 0, max_text_len)

    # Pad to fill the row
    total_drawn = prefix_len + String.length(display_text)
    pad = if total_drawn < width, do: String.duplicate(" ", width - total_drawn), else: ""

    # Editing row uses inverse video (selection highlight)
    editing_bg = theme.tree.dir_fg
    editing_fg = theme.tree.bg

    guide_style = Face.new(fg: editing_fg, bg: editing_bg)
    icon_style = Face.new(fg: editing_fg, bg: editing_bg)
    text_style = Face.new(fg: editing_fg, bg: editing_bg, bold: true)

    draws = []

    draws =
      if guide_len > 0 do
        draws ++ [DisplayList.draw(row, col, guide_prefix, guide_style)]
      else
        draws
      end

    icon_col = col + guide_len
    draws = draws ++ [DisplayList.draw(row, icon_col, icon <> " ", icon_style)]

    text_col = col + prefix_len
    draws = draws ++ [DisplayList.draw(row, text_col, display_text <> pad, text_style)]

    draws
  end

  # ── Indent guides ──────────────────────────────────────────────────────

  @spec build_guides([boolean()], boolean()) :: String.t()
  defp build_guides(ancestor_guides, last_child?) do
    # Ancestor columns: each is either │ (more siblings) or blank (last child)
    ancestor_part =
      Enum.map_join(ancestor_guides, fn
        true -> @guide_pipe
        false -> @guide_blank
      end)

    # The connector at this entry's own depth
    # Depth-0 entries (direct children of root) also get a connector
    connector =
      if last_child? do
        @guide_elbow
      else
        @guide_tee
      end

    ancestor_part <> connector
  end

  # ── Icon selection ──────────────────────────────────────────────────────

  @spec entry_icon(Row.t()) :: {String.t(), non_neg_integer()}
  defp entry_icon(%Row{directory?: true, expanded?: true}) do
    {@folder_open, 0x519ABA}
  end

  defp entry_icon(%Row{directory?: true}) do
    {@folder_closed, 0x519ABA}
  end

  defp entry_icon(%Row{path: path}) do
    filetype = Language.detect_filetype(path)
    Devicon.icon_and_color(filetype)
  end

  # ── Style helpers ──────────────────────────────────────────────────────

  # Visual state priority is layered, not mutually exclusive:
  # inline editing owns the whole row, then selection owns the row background.
  # Active file owns name/icon emphasis, dirty owns the modified-buffer marker.
  # Git owns the git marker, and directory emphasis is the base fallback.
  @spec row_background(boolean(), boolean(), Theme.t()) :: Face.t()
  defp row_background(true = _is_cursor, true = _focused, theme) do
    Face.new(bg: theme.tree.cursor_bg)
  end

  defp row_background(true = _is_cursor, false = _focused, theme) do
    Face.new(bg: theme.tree.separator_fg)
  end

  defp row_background(false = _is_cursor, _focused, theme) do
    Face.new(bg: theme.tree.bg)
  end

  @spec guide_draw_style(boolean(), boolean(), Theme.t()) :: Face.t()
  defp guide_draw_style(is_cursor, focused, theme) do
    Face.new(fg: theme.tree.separator_fg, bg: row_bg_color(is_cursor, focused, theme))
  end

  @spec icon_draw_style(non_neg_integer(), boolean(), boolean(), Theme.t()) :: Face.t()
  defp icon_draw_style(icon_color, is_cursor, focused, theme) do
    Face.new(fg: icon_color, bg: row_bg_color(is_cursor, focused, theme))
  end

  @spec dirty_indicator_style(boolean(), boolean(), Theme.t()) :: Face.t()
  defp dirty_indicator_style(is_cursor, focused, theme) do
    color = theme.tree.modified_fg || theme.tree.fg
    Face.new(fg: color, bg: row_bg_color(is_cursor, focused, theme), bold: true)
  end

  @spec git_indicator_style(
          Minga.Project.FileTree.GitStatus.file_status(),
          boolean(),
          boolean(),
          Theme.t()
        ) :: Face.t()
  defp git_indicator_style(status, is_cursor, focused, theme) do
    Face.new(
      fg: git_status_color(status, theme),
      bg: row_bg_color(is_cursor, focused, theme),
      bold: status == :conflict
    )
  end

  @spec git_status_color(Minga.Project.FileTree.GitStatus.file_status(), Theme.t()) ::
          non_neg_integer()
  defp git_status_color(:modified, theme), do: theme.tree.git_modified_fg || theme.tree.fg
  defp git_status_color(:staged, theme), do: theme.tree.git_staged_fg || theme.tree.fg
  defp git_status_color(:untracked, theme), do: theme.tree.git_untracked_fg || theme.tree.fg
  defp git_status_color(:conflict, theme), do: theme.tree.git_conflict_fg || theme.tree.fg
  defp git_status_color(:renamed, theme), do: theme.tree.git_staged_fg || theme.tree.fg
  defp git_status_color(:deleted, theme), do: theme.tree.git_conflict_fg || theme.tree.fg

  @spec row_bg_color(boolean(), boolean(), Theme.t()) :: non_neg_integer()
  defp row_bg_color(is_cursor, focused, theme), do: row_background(is_cursor, focused, theme).bg

  @spec name_draw_style(Row.t(), boolean(), boolean(), boolean(), Theme.t()) :: Face.t()
  defp name_draw_style(tree_row, is_cursor, is_active, focused, theme) do
    base_fg = name_foreground(tree_row, is_active, theme)

    Face.new(
      fg: base_fg,
      bg: row_bg_color(is_cursor, focused, theme),
      bold: is_active or tree_row.directory?
    )
  end

  @spec name_foreground(Row.t(), boolean(), Theme.t()) :: non_neg_integer()
  defp name_foreground(_tree_row, true = _is_active, theme), do: theme.tree.active_fg
  defp name_foreground(%Row{directory?: true}, false = _is_active, theme), do: theme.tree.dir_fg
  defp name_foreground(_tree_row, false = _is_active, theme), do: theme.tree.fg

  # ── Blanks, separator, scroll ──────────────────────────────────────────

  @spec render_blanks(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          Theme.t()
        ) :: [DisplayList.draw()]
  defp render_blanks(rendered, total, _row_start, _col, _width, _theme)
       when rendered >= total do
    []
  end

  defp render_blanks(rendered, total, row_start, col, width, theme) do
    blank = String.duplicate(" ", width)
    style = Face.new(fg: theme.tree.fg, bg: theme.tree.bg)

    for i <- rendered..(total - 1) do
      DisplayList.draw(row_start + i, col, blank, style)
    end
  end

  @spec render_separator(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          Theme.t()
        ) :: [DisplayList.draw()]
  defp render_separator(col, row_start, height, theme) do
    style = Face.new(fg: theme.tree.separator_fg, bg: theme.tree.bg)

    for row <- row_start..(row_start + height - 1) do
      DisplayList.draw(row, col, "│", style)
    end
  end

  @spec scroll_offset(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp scroll_offset(cursor, visible_rows) when visible_rows <= 0, do: cursor
  defp scroll_offset(cursor, visible_rows) when cursor < visible_rows, do: 0

  defp scroll_offset(cursor, visible_rows) do
    cursor - visible_rows + 1
  end

  @spec selected_index([Row.t()]) :: non_neg_integer()
  defp selected_index(rows) do
    case Enum.find_index(rows, & &1.selected?) do
      nil -> 0
      index -> index
    end
  end

  # Computes the tree rect from workspace data without requiring EditorState.
  @spec tree_rect_from_workspace(map()) :: MingaEditor.WindowTree.rect() | nil
  defp tree_rect_from_workspace(%{file_tree: %{tree: nil}}), do: nil

  defp tree_rect_from_workspace(%{
         viewport: %{rows: rows},
         file_tree: %{tree: %Minga.Project.FileTree{width: tw}}
       }) do
    {1, 0, tw, rows - 2}
  end
end
