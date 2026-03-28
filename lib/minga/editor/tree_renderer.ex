defmodule Minga.Editor.TreeRenderer do
  @moduledoc """
  Renders the file tree panel into draw tuples for the left side of the screen.

  Produces a list of `DisplayList.draw()` tuples for the tree entries,
  the separator column, and the header line. Uses Nerd Font icons per
  filetype, box-drawing indent guides, and a project-name header to
  match neo-tree.nvim's visual style.
  """

  alias Minga.Buffer
  alias Minga.Core.Face
  alias Minga.Editor.DisplayList
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.WindowTree
  alias Minga.Language
  alias Minga.Project.FileTree
  alias Minga.UI.Devicon
  alias Minga.UI.Theme

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
      dirty_paths: MapSet.new()
    ]

    @type t :: %__MODULE__{
            tree: FileTree.t(),
            rect: WindowTree.rect(),
            focused: boolean(),
            theme: Theme.t(),
            active_path: String.t() | nil,
            editing: FileTreeState.editing() | nil,
            git_status: Minga.Project.FileTree.GitStatus.status_map(),
            dirty_paths: MapSet.t(String.t())
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
    do_render(
      input.tree,
      input.rect,
      input.focused,
      input.theme,
      input.active_path,
      input.editing,
      input.git_status,
      input.dirty_paths
    )
  end

  @spec render(EditorState.t()) :: [DisplayList.draw()]
  def render(%EditorState{workspace: %{file_tree: %{tree: nil}}}), do: []

  def render(%EditorState{workspace: %{file_tree: %{tree: tree, focused: focused}}} = state) do
    case EditorState.tree_rect(state) do
      nil ->
        []

      rect ->
        input = %RenderInput{
          tree: tree,
          rect: rect,
          focused: focused,
          theme: state.theme,
          active_path: active_buffer_path(state),
          editing: state.workspace.file_tree.editing,
          git_status: tree.git_status,
          dirty_paths: compute_dirty_paths(state)
        }

        render(input)
    end
  end

  @spec do_render(
          FileTree.t(),
          WindowTree.rect(),
          boolean(),
          Theme.t(),
          String.t() | nil,
          FileTreeState.editing() | nil,
          FileTree.GitStatus.status_map(),
          MapSet.t(String.t())
        ) :: [DisplayList.draw()]
  defp do_render(
         tree,
         {row_off, col_off, width, height},
         focused,
         theme,
         active_path,
         editing,
         git_status,
         dirty_paths
       ) do
    entries = FileTree.visible_entries(tree)

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
    scroll_offset = scroll_offset(tree.cursor, content_rows)

    render_opts = %{
      cursor: tree.cursor,
      focused: focused,
      active_path: active_path,
      col_off: col_off,
      width: width,
      theme: theme,
      expanded: tree.expanded,
      editing: editing,
      git_status: git_status,
      dirty_paths: dirty_paths
    }

    entry_commands =
      entries
      |> Enum.with_index()
      |> Enum.drop(scroll_offset)
      |> Enum.take(content_rows)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{entry, global_idx}, screen_row} ->
        row = row_off + 1 + screen_row

        if editing != nil and global_idx == editing.index do
          render_editing_entry(entry, row, render_opts)
        else
          render_entry(entry, global_idx, row, render_opts)
        end
      end)

    # Fill remaining rows with blanks
    visible_count = entries |> Enum.drop(scroll_offset) |> Enum.take(content_rows) |> length()

    blank_commands =
      render_blanks(visible_count, content_rows, row_off + 1, col_off, width, theme)

    # Separator column (one column right of the tree area)
    sep_col = col_off + width
    sep_commands = render_separator(sep_col, row_off, height, theme)

    header ++ entry_commands ++ blank_commands ++ sep_commands
  end

  # ── Entry rendering ──────────────────────────────────────────────────────

  @spec render_entry(FileTree.entry(), non_neg_integer(), non_neg_integer(), map()) ::
          [DisplayList.draw()]
  defp render_entry(entry, idx, row, opts) do
    %{
      cursor: cursor,
      focused: focused,
      active_path: active_path,
      col_off: col,
      width: width,
      theme: theme,
      expanded: expanded,
      git_status: git_status,
      dirty_paths: dirty_paths
    } = opts

    is_cursor = idx == cursor
    is_active = active_path != nil and entry.path == active_path
    is_expanded = entry.dir? and MapSet.member?(expanded, entry.path)
    is_dirty = not entry.dir? and MapSet.member?(dirty_paths, entry.path)

    # Build the guide prefix from the entry's ancestor guide flags
    guide_prefix = build_guides(entry.guides, entry.last_child?)

    # Pick the icon and its color
    {icon, icon_color} = entry_icon(entry, is_expanded)

    # Entry name (dirs get trailing slash)
    name = if entry.dir?, do: entry.name <> "/", else: entry.name

    # Right-side indicators: [modified_dot] [git_status]
    # Modified dot = 1 col, git status = 2 cols (space + symbol)
    file_git_status = Map.get(git_status, entry.path)
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
    name_style = name_draw_style(entry, is_cursor, is_active, focused, theme)

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
  @spec render_editing_entry(FileTree.entry(), non_neg_integer(), map()) :: [DisplayList.draw()]
  defp render_editing_entry(entry, row, opts) do
    %{col_off: col, width: width, theme: theme, editing: editing} = opts

    # Build indent guides (same depth as the entry being edited/created)
    guide_prefix = build_guides(entry.guides, entry.last_child?)
    guide_len = String.length(guide_prefix)

    # Type indicator: file icon for new file, folder icon for new folder,
    # the entry's own icon for rename
    {icon, _icon_color} =
      case editing.type do
        :new_file -> {"", 0x519ABA}
        :new_folder -> {@folder_open, 0x519ABA}
        :rename -> entry_icon(entry, false)
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

  @spec entry_icon(FileTree.entry(), boolean()) :: {String.t(), non_neg_integer()}
  defp entry_icon(%{dir?: true}, true = _expanded) do
    {@folder_open, 0x519ABA}
  end

  defp entry_icon(%{dir?: true}, false = _expanded) do
    {@folder_closed, 0x519ABA}
  end

  defp entry_icon(%{path: path}, _expanded) do
    filetype = Language.detect_filetype(path)
    Devicon.icon_and_color(filetype)
  end

  # ── Style helpers ──────────────────────────────────────────────────────

  @spec row_background(boolean(), boolean(), Theme.t()) :: Face.t()
  defp row_background(true = _is_cursor, true = _focused, theme) do
    Face.new(bg: theme.tree.dir_fg)
  end

  defp row_background(true = _is_cursor, false = _focused, theme) do
    Face.new(bg: theme.tree.cursor_bg)
  end

  defp row_background(false = _is_cursor, _focused, theme) do
    Face.new(bg: theme.tree.bg)
  end

  @spec guide_draw_style(boolean(), boolean(), Theme.t()) :: Face.t()
  defp guide_draw_style(true = _is_cursor, true = _focused, theme) do
    Face.new(fg: theme.tree.bg, bg: theme.tree.dir_fg)
  end

  defp guide_draw_style(true = _is_cursor, false = _focused, theme) do
    Face.new(fg: theme.tree.separator_fg, bg: theme.tree.cursor_bg)
  end

  defp guide_draw_style(_is_cursor, _focused, theme) do
    Face.new(fg: theme.tree.separator_fg, bg: theme.tree.bg)
  end

  @spec icon_draw_style(non_neg_integer(), boolean(), boolean(), Theme.t()) :: Face.t()
  defp icon_draw_style(_icon_color, true = _is_cursor, true = _focused, theme) do
    # Focused cursor row: invert, use bg as fg
    Face.new(fg: theme.tree.bg, bg: theme.tree.dir_fg)
  end

  defp icon_draw_style(icon_color, true = _is_cursor, false = _focused, theme) do
    Face.new(fg: icon_color, bg: theme.tree.cursor_bg)
  end

  defp icon_draw_style(icon_color, _is_cursor, _focused, theme) do
    Face.new(fg: icon_color, bg: theme.tree.bg)
  end

  @spec dirty_indicator_style(boolean(), boolean(), Theme.t()) :: Face.t()
  defp dirty_indicator_style(true = _is_cursor, true = _focused, theme) do
    color = theme.tree.modified_fg || theme.tree.fg
    Face.new(fg: theme.tree.bg, bg: color)
  end

  defp dirty_indicator_style(true = _is_cursor, false = _focused, theme) do
    color = theme.tree.modified_fg || theme.tree.fg
    Face.new(fg: color, bg: theme.tree.cursor_bg)
  end

  defp dirty_indicator_style(_is_cursor, _focused, theme) do
    color = theme.tree.modified_fg || theme.tree.fg
    Face.new(fg: color, bg: theme.tree.bg)
  end

  @spec git_indicator_style(
          Minga.Project.FileTree.GitStatus.file_status(),
          boolean(),
          boolean(),
          Theme.t()
        ) :: Face.t()
  defp git_indicator_style(status, true = _is_cursor, true = _focused, theme) do
    # Focused cursor row: invert
    Face.new(fg: theme.tree.bg, bg: git_status_color(status, theme))
  end

  defp git_indicator_style(status, true = _is_cursor, false = _focused, theme) do
    Face.new(fg: git_status_color(status, theme), bg: theme.tree.cursor_bg)
  end

  defp git_indicator_style(status, _is_cursor, _focused, theme) do
    Face.new(fg: git_status_color(status, theme), bg: theme.tree.bg)
  end

  @spec git_status_color(Minga.Project.FileTree.GitStatus.file_status(), Theme.t()) ::
          non_neg_integer()
  defp git_status_color(:modified, theme), do: theme.tree.git_modified_fg || theme.tree.fg
  defp git_status_color(:staged, theme), do: theme.tree.git_staged_fg || theme.tree.fg
  defp git_status_color(:untracked, theme), do: theme.tree.git_untracked_fg || theme.tree.fg
  defp git_status_color(:conflict, theme), do: theme.tree.git_conflict_fg || theme.tree.fg
  defp git_status_color(:renamed, theme), do: theme.tree.git_staged_fg || theme.tree.fg
  defp git_status_color(:deleted, theme), do: theme.tree.git_conflict_fg || theme.tree.fg

  @spec name_draw_style(FileTree.entry(), boolean(), boolean(), boolean(), Theme.t()) :: Face.t()
  defp name_draw_style(entry, is_cursor, is_active, focused, theme) do
    tree = theme.tree

    base_fg =
      case {entry.dir?, is_active} do
        {true, _} -> tree.dir_fg
        {_, true} -> tree.active_fg
        _ -> tree.fg
      end

    case {is_cursor, focused} do
      {true, true} ->
        Face.new(fg: tree.bg, bg: base_fg, bold: entry.dir?)

      {true, false} ->
        Face.new(fg: base_fg, bg: tree.cursor_bg, bold: entry.dir?)

      _ ->
        Face.new(fg: base_fg, bg: tree.bg, bold: entry.dir?)
    end
  end

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

  @spec active_buffer_path(EditorState.t()) :: String.t() | nil
  defp active_buffer_path(%{workspace: %{buffers: %{active: nil}}}), do: nil

  defp active_buffer_path(%{workspace: %{buffers: %{active: buf}}}) do
    case Buffer.file_path(buf) do
      nil -> nil
      path -> Path.expand(path)
    end
  end

  @spec compute_dirty_paths(EditorState.t()) :: MapSet.t(String.t())
  defp compute_dirty_paths(%{workspace: %{buffers: %{list: buffer_list}}}) do
    buffer_list
    |> Enum.flat_map(fn pid ->
      try do
        if Buffer.dirty?(pid), do: [Buffer.file_path(pid)], else: []
      catch
        :exit, _ -> []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> MapSet.new()
  end
end
