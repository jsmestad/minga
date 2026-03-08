defmodule Minga.Editor.TreeRenderer do
  @moduledoc """
  Renders the file tree panel into draw tuples for the left side of the screen.

  Produces a list of `DisplayList.draw()` tuples for the tree entries,
  the separator column, and the header line.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.DisplayList
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.WindowTree
  alias Minga.FileTree
  alias Minga.Theme

  @indent_size 2

  @doc """
  Renders the file tree panel.

  Returns a list of `DisplayList.draw()` tuples for the tree content,
  separator, and header.
  """
  @spec render(EditorState.t()) :: [DisplayList.draw()]
  def render(%EditorState{file_tree: %{tree: nil}}), do: []

  def render(%EditorState{file_tree: %{tree: tree, focused: focused}} = state) do
    case EditorState.tree_rect(state) do
      nil -> []
      rect -> do_render(tree, rect, focused, state)
    end
  end

  @spec do_render(FileTree.t(), WindowTree.rect(), boolean(), EditorState.t()) ::
          [DisplayList.draw()]
  defp do_render(tree, {row_off, col_off, width, height}, focused, state) do
    entries = FileTree.visible_entries(tree)
    theme = state.theme
    active_path = active_buffer_path(state)

    # Header row
    header_text = " File Tree" |> String.pad_trailing(width)

    header = [
      DisplayList.draw(row_off, col_off, header_text,
        fg: theme.tree.header_fg,
        bg: theme.tree.header_bg,
        bold: true
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
      expanded: tree.expanded
    }

    entry_commands =
      entries
      |> Enum.with_index()
      |> Enum.drop(scroll_offset)
      |> Enum.take(content_rows)
      |> Enum.with_index()
      |> Enum.map(fn {{entry, global_idx}, screen_row} ->
        render_entry(entry, global_idx, row_off + 1 + screen_row, render_opts)
      end)

    # Fill remaining rows with blanks
    rendered_count = length(entry_commands)

    blank_commands =
      render_blanks(rendered_count, content_rows, row_off + 1, col_off, width, theme)

    # Separator column (one column right of the tree area)
    sep_col = col_off + width
    sep_commands = render_separator(sep_col, row_off, height, theme)

    header ++ entry_commands ++ blank_commands ++ sep_commands
  end

  @spec render_entry(FileTree.entry(), non_neg_integer(), non_neg_integer(), map()) ::
          DisplayList.draw()
  defp render_entry(entry, idx, row, opts) do
    %{
      cursor: cursor,
      focused: focused,
      active_path: active_path,
      col_off: col,
      width: width,
      theme: theme,
      expanded: expanded
    } = opts

    is_expanded = entry.dir? and MapSet.member?(expanded, entry.path)
    indent = String.duplicate(" ", entry.depth * @indent_size)

    icon =
      case {entry.dir?, is_expanded} do
        {true, true} -> "▾ "
        {true, false} -> "▸ "
        {false, _} -> "  "
      end

    label = indent <> icon <> entry.name
    display = String.slice(label, 0, width) |> String.pad_trailing(width)

    is_cursor = idx == cursor
    is_active = active_path != nil and entry.path == active_path

    style = entry_style(entry, is_cursor, is_active, focused, theme)

    DisplayList.draw(row, col, display, style)
  end

  @spec entry_style(FileTree.entry(), boolean(), boolean(), boolean(), Theme.t()) :: keyword()
  defp entry_style(entry, is_cursor, is_active, focused, theme) do
    tree = theme.tree

    base_fg =
      case {entry.dir?, is_active} do
        {true, _} -> tree.dir_fg
        {_, true} -> tree.active_fg
        _ -> tree.fg
      end

    case {is_cursor, focused} do
      {true, true} ->
        [fg: tree.bg, bg: base_fg, bold: entry.dir?]

      {true, false} ->
        [fg: base_fg, bg: tree.cursor_bg, bold: entry.dir?]

      _ ->
        [fg: base_fg, bg: tree.bg, bold: entry.dir?]
    end
  end

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
    style = [fg: theme.tree.fg, bg: theme.tree.bg]

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
    style = [fg: theme.tree.separator_fg, bg: theme.tree.bg]

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
  defp active_buffer_path(%{buffers: %{active: nil}}), do: nil

  defp active_buffer_path(%{buffers: %{active: buf}}) do
    case BufferServer.file_path(buf) do
      nil -> nil
      path -> Path.expand(path)
    end
  end
end
