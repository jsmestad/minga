defmodule MingaFileTree.Shell.Traditional.TreeRenderer do
  @moduledoc """
  Renders the file tree panel into draw tuples for the left side of the screen.

  Produces a list of `DisplayList.draw()` tuples for the tree entries,
  the separator column, and the header line. Uses stable disclosure,
  icon, name, and status columns with quiet ancestor guides so the tree
  stays scannable without connector-heavy branch art.
  """

  alias Minga.Buffer
  alias Minga.Core.Face
  alias Minga.Core.Unicode
  alias Minga.Language
  alias Minga.Project.FileTree
  alias MingaEditor.DisplayList
  alias MingaFileTree.Diagnostics
  alias MingaFileTree.Row
  alias MingaFileTree.Rows
  alias MingaEditor.State, as: EditorState
  alias MingaFileTree.State, as: FileTreeState
  alias MingaEditor.UI.Devicon
  alias MingaEditor.UI.Theme
  alias MingaEditor.WindowTree

  # Row anatomy: faint ancestor guides, disclosure, icon, name, spacer, diagnostic marker, dirty marker, git marker.
  @guide_pipe "│ "
  @guide_blank "  "
  @disclosure_expanded "▾ "
  @disclosure_collapsed "▸ "
  @disclosure_file "  "
  @guide_ellipsis "… "
  @name_ellipsis "…"
  @minimum_name_width 4
  @minimum_editing_text_width 1

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
      rows: nil,
      status: :ready,
      filter_text: nil,
      filtering?: false,
      help_visible?: false
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
            rows: [Row.t()] | nil,
            status: FileTreeState.tree_status(),
            filter_text: String.t() | nil,
            filtering?: boolean(),
            help_visible?: boolean()
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
    do_render(input)
  end

  @spec render(EditorState.t() | map()) :: [DisplayList.draw()]
  def render(state) do
    case EditorState.file_tree_state(state) do
      %FileTreeState{tree: nil} -> []
      %FileTreeState{tree: _tree} = file_tree -> render_from_file_tree(file_tree, state)
    end
  end

  @spec render_from_file_tree(FileTreeState.t(), map()) :: [DisplayList.draw()]
  defp render_from_file_tree(%FileTreeState{tree: tree, focused: focused} = file_tree, state) do
    rect = tree_rect_from_workspace(state.workspace, file_tree)

    input = %RenderInput{
      tree: tree,
      rect: rect,
      focused: focused,
      theme: state.theme,
      active_path: active_buffer_path(state),
      dirty_paths: dirty_paths(state),
      editing: file_tree.editing,
      filter_text: Map.get(tree, :filter),
      filtering?: file_tree.filtering,
      git_status: tree.git_status,
      help_visible?: file_tree.help_visible,
      status: status_from_file_tree(file_tree)
    }

    render(input)
  end

  @spec do_render(RenderInput.t()) :: [DisplayList.draw()]
  defp do_render(%RenderInput{rect: {_row_off, _col_off, width, height}})
       when width <= 0 or height <= 0,
       do: []

  defp do_render(%RenderInput{help_visible?: true} = input), do: render_help_panel(input)

  defp do_render(
         %RenderInput{tree: tree, rect: {row_off, col_off, width, height}, theme: theme} = input
       ) do
    header_text = header_text(input, tree)
    header_display = Unicode.pad_display_trailing(header_text, width)

    header = [
      DisplayList.draw(
        row_off,
        col_off,
        header_display,
        Face.new(fg: theme.tree.header_fg, bg: theme.tree.header_bg, bold: true)
      )
    ]

    # Entry rows (starting from row 1, leaving row 0 for header)
    content_rows = max(height - 1, 0)
    {status, rows, visible_count} = visible_rows_for_input(input, content_rows)

    render_opts = %{
      col_off: col_off,
      width: width,
      theme: theme
    }

    entry_commands =
      render_content_rows(status, rows, content_rows, row_off + 1, render_opts)

    # Fill remaining rows with blanks
    blank_commands =
      render_blanks(visible_count, content_rows, row_off + 1, col_off, width, theme)

    # Separator column (one column right of the tree area)
    sep_col = col_off + width
    sep_commands = render_separator(sep_col, row_off, height, theme)

    header ++ entry_commands ++ blank_commands ++ sep_commands
  end

  @spec render_help_panel(RenderInput.t()) :: [DisplayList.draw()]
  defp render_help_panel(%RenderInput{rect: {row_off, col_off, width, height}, theme: theme}) do
    blank = String.duplicate(" ", width)
    bg_face = Face.new(fg: theme.tree.fg, bg: theme.tree.bg)

    background =
      for row <- 0..(height - 1) do
        DisplayList.draw(row_off + row, col_off, blank, bg_face)
      end

    title_face = Face.new(fg: theme.tree.header_fg, bg: theme.tree.header_bg, bold: true)
    label_face = Face.new(fg: theme.tree.dir_fg, bg: theme.tree.bg, bold: true)
    key_face = Face.new(fg: theme.tree.fg, bg: theme.tree.bg, bold: true)
    desc_face = Face.new(fg: theme.tree.separator_fg, bg: theme.tree.bg)

    header = [
      DisplayList.draw(
        row_off,
        col_off,
        Unicode.pad_display_trailing(" Keyboard Shortcuts", width),
        title_face
      )
    ]

    help_draws =
      render_help_groups(
        MingaFileTree.Keymap.Scope.help_groups(:default),
        row_off + 2,
        col_off,
        width,
        max(height - 2, 0),
        label_face,
        key_face,
        desc_face
      )

    separator = render_separator(col_off + width, row_off, height, theme)
    background ++ header ++ help_draws ++ separator
  end

  @spec render_help_groups(
          [{String.t(), [{String.t(), String.t()}]}],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          Face.t(),
          Face.t(),
          Face.t()
        ) :: [DisplayList.draw()]
  defp render_help_groups(groups, row, col, width, rows_left, label_face, key_face, desc_face) do
    {draws, _row, _remaining} =
      Enum.reduce(groups, {[], row, rows_left}, fn group, acc ->
        render_help_group_block(group, acc, col, width, label_face, key_face, desc_face)
      end)

    Enum.reverse(draws)
  end

  @spec render_help_group_block(
          {String.t(), [{String.t(), String.t()}]},
          {[DisplayList.draw()], non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          pos_integer(),
          Face.t(),
          Face.t(),
          Face.t()
        ) :: {[DisplayList.draw()], non_neg_integer(), non_neg_integer()}
  defp render_help_group_block(
         _group,
         {draws, row, remaining},
         _col,
         _width,
         _label_face,
         _key_face,
         _desc_face
       )
       when remaining <= 0,
       do: {draws, row, 0}

  defp render_help_group_block(
         {title, bindings},
         {draws, row, remaining},
         col,
         width,
         label_face,
         key_face,
         desc_face
       ) do
    title_draw =
      DisplayList.draw(
        row,
        col + 2,
        Unicode.truncate_display_width(title, max(width - 4, 0)),
        label_face
      )

    {binding_draws, row, remaining} =
      render_help_bindings(bindings, row + 1, remaining - 1, col, width, key_face, desc_face)

    {[title_draw | binding_draws] ++ draws, row + 1, remaining - 1}
  end

  @spec render_help_bindings(
          [{String.t(), String.t()}],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          Face.t(),
          Face.t()
        ) :: {[DisplayList.draw()], non_neg_integer(), non_neg_integer()}
  defp render_help_bindings(bindings, row, remaining, col, width, key_face, desc_face) do
    Enum.reduce(bindings, {[], row, remaining}, fn binding, acc ->
      render_help_binding_row(binding, acc, col, width, key_face, desc_face)
    end)
  end

  @spec render_help_binding_row(
          {String.t(), String.t()},
          {[DisplayList.draw()], non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          pos_integer(),
          Face.t(),
          Face.t()
        ) :: {[DisplayList.draw()], non_neg_integer(), non_neg_integer()}
  defp render_help_binding_row(
         _binding,
         {draws, row, remaining},
         _col,
         _width,
         _key_face,
         _desc_face
       )
       when remaining <= 0,
       do: {draws, row, 0}

  defp render_help_binding_row(
         {key, desc},
         {draws, row, remaining},
         col,
         width,
         key_face,
         desc_face
       ) do
    key_width = min(div(width, 3), 12)
    key_text = key |> String.pad_trailing(key_width) |> Unicode.truncate_display_width(key_width)
    desc_text = Unicode.truncate_display_width(desc, max(width - key_width - 6, 0))

    row_draws = [
      DisplayList.draw(row, col + 4, key_text, key_face),
      DisplayList.draw(row, col + 4 + key_width, desc_text, desc_face)
    ]

    {row_draws ++ draws, row + 1, remaining - 1}
  end

  @spec header_text(RenderInput.t(), FileTree.t()) :: String.t()
  defp header_text(%RenderInput{filtering?: true, filter_text: filter}, _tree) do
    " / " <> (filter || "") <> "▏"
  end

  defp header_text(%RenderInput{filter_text: filter}, _tree)
       when is_binary(filter) and filter != "" do
    " / " <> filter
  end

  defp header_text(%RenderInput{}, tree) do
    project_name = Path.basename(tree.root)
    " #{@folder_open} #{project_name}/"
  end

  @spec status_from_file_tree(FileTreeState.t()) :: FileTreeState.tree_status()
  defp status_from_file_tree(%FileTreeState{} = file_tree), do: FileTreeState.status(file_tree)

  @spec active_buffer_path(EditorState.t() | map()) :: String.t() | nil
  defp active_buffer_path(%{workspace: %{buffers: %{active: nil}}}), do: nil

  defp active_buffer_path(%{workspace: %{buffers: %{active: buf}}}) do
    case Buffer.file_path(buf) do
      nil -> nil
      path -> Path.expand(path)
    end
  catch
    :exit, _ -> nil
  end

  defp active_buffer_path(_state), do: nil

  defp dirty_paths(%{workspace: %{buffers: %{list: buffer_list}}}) do
    buffer_list
    |> Enum.flat_map(&dirty_buffer_path/1)
    |> Enum.map(&Path.expand/1)
    |> MapSet.new()
  end

  defp dirty_paths(_state), do: MapSet.new()

  @spec dirty_buffer_path(pid()) :: [String.t()]
  defp dirty_buffer_path(pid) when is_pid(pid) do
    if Buffer.dirty?(pid), do: present_path(Buffer.file_path(pid)), else: []
  catch
    :exit, _ -> []
  end

  @spec present_path(String.t() | nil) :: [String.t()]
  defp present_path(nil), do: []
  defp present_path(path), do: [path]

  @spec effective_status(FileTreeState.tree_status(), list()) :: FileTreeState.tree_status()
  defp effective_status(:ready, []), do: :empty
  defp effective_status(status, _rows), do: status

  @spec visible_rows_for_input(RenderInput.t(), non_neg_integer()) ::
          {FileTreeState.tree_status(), [Row.t()], non_neg_integer()}
  defp visible_rows_for_input(%RenderInput{rows: rows, status: status}, content_rows)
       when is_list(rows) do
    status = effective_status(status, rows)
    visible_rows = visible_rows(status, rows, content_rows)
    {status, visible_rows, length(visible_rows)}
  end

  defp visible_rows_for_input(%RenderInput{} = input, content_rows) do
    entries = FileTree.visible_entries(input.tree)
    status = effective_status(input.status, entries)
    visible_entries = visible_entries(status, entries, input.tree.cursor, content_rows)

    rows =
      Rows.from_entries(visible_entries, input.tree,
        active_path: input.active_path,
        dirty_paths: input.dirty_paths,
        editing: input.editing,
        focused: input.focused,
        git_status: input.git_status,
        selected_index: input.tree.cursor
      )

    {status, rows, visible_count(status, rows, content_rows)}
  end

  @spec visible_count(FileTreeState.tree_status(), [Row.t()], non_neg_integer()) ::
          non_neg_integer()
  defp visible_count(:ready, rows, _content_rows), do: length(rows)

  defp visible_count(status, _rows, content_rows) do
    status |> state_lines() |> Enum.take(content_rows) |> length()
  end

  @spec visible_rows(FileTreeState.tree_status(), [Row.t()], non_neg_integer()) :: [Row.t()]
  defp visible_rows(:ready, _rows, 0), do: []

  defp visible_rows(:ready, rows, content_rows) do
    rows
    |> selected_index()
    |> visible_range(content_rows)
    |> then(&Enum.slice(rows, &1))
  end

  defp visible_rows(status, _rows, content_rows) do
    status
    |> state_lines()
    |> Enum.take(content_rows)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      Row.new(
        id: "state:#{index}",
        path: "",
        name: line,
        directory?: false,
        expanded?: false,
        depth: 0,
        guides: [],
        last_child?: true
      )
    end)
  end

  @spec visible_entries(
          FileTreeState.tree_status(),
          [FileTree.entry()],
          non_neg_integer(),
          non_neg_integer()
        ) ::
          [Rows.indexed_entry()]
  defp visible_entries(:ready, _entries, _cursor, 0), do: []

  defp visible_entries(:ready, entries, cursor, content_rows) do
    range = visible_range(cursor, content_rows)

    entries
    |> Enum.slice(range)
    |> Enum.with_index(range.first)
  end

  defp visible_entries(_status, _entries, _cursor, _content_rows), do: []

  @spec visible_range(non_neg_integer(), non_neg_integer()) :: Range.t()
  defp visible_range(cursor, content_rows) do
    offset = scroll_offset(cursor, content_rows)
    offset..(offset + content_rows - 1)//1
  end

  @spec render_content_rows(
          FileTreeState.tree_status(),
          [Row.t()],
          non_neg_integer(),
          non_neg_integer(),
          map()
        ) :: [DisplayList.draw()]
  defp render_content_rows(:ready, rows, _content_rows, first_row, opts) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {tree_row, screen_row} ->
      row = first_row + screen_row

      if tree_row.editing != nil do
        render_editing_entry(tree_row, row, opts)
      else
        render_entry(tree_row, row, opts)
      end
    end)
  end

  defp render_content_rows(status, _rows, content_rows, first_row, opts) do
    status
    |> state_lines()
    |> Enum.take(content_rows)
    |> Enum.with_index()
    |> Enum.map(fn {line, screen_row} ->
      render_state_line(line, first_row + screen_row, opts)
    end)
  end

  @spec state_lines(FileTreeState.tree_status()) :: [String.t()]
  defp state_lines(:loading), do: ["  ⏳ Loading files…"]
  defp state_lines(:empty), do: ["  No files yet", "  Press n to create a file"]
  defp state_lines({:error, reason}), do: ["  ⚠ File tree error", "  #{reason}"]
  defp state_lines(_status), do: []

  @spec render_state_line(String.t(), non_neg_integer(), map()) :: DisplayList.draw()
  defp render_state_line(line, row, %{col_off: col, width: width, theme: theme}) do
    text = line |> Unicode.truncate_display_width(width) |> Unicode.pad_display_trailing(width)
    DisplayList.draw(row, col, text, Face.new(fg: theme.tree.fg, bg: theme.tree.bg))
  end

  # ── Entry rendering ──────────────────────────────────────────────────────

  @spec render_entry(Row.t(), non_neg_integer(), map()) :: [DisplayList.draw()]
  defp render_entry(tree_row, row, opts) do
    %{col_off: col, width: width, theme: theme} = opts

    is_cursor = tree_row.selected?
    focused = tree_row.focused?
    is_dirty = tree_row.dirty?
    diagnostic_text = diagnostic_indicator_text(tree_row.diagnostics)

    # Entry name (dirs get trailing slash). Middle truncation keeps the useful beginning and extension visible.
    name = if tree_row.directory?, do: tree_row.name <> "/", else: tree_row.name

    # Reserve right-side indicators before spending width on deep indentation.
    fixed_prefix_width = fixed_prefix_width(tree_row)

    {diagnostic_text, is_dirty, file_git_status} =
      fit_indicators(
        diagnostic_text,
        is_dirty,
        tree_row.git_status,
        max(width - fixed_prefix_width, 0)
      )

    diagnostic_width = Unicode.display_width(diagnostic_text)
    git_width = if file_git_status, do: 2, else: 0
    dirty_width = if is_dirty, do: 1, else: 0
    indicator_width = diagnostic_width + dirty_width + git_width

    {prefix, structure_prefix, icon, icon_color} =
      row_prefix(tree_row, width, indicator_width, @minimum_name_width)

    prefix_width = Unicode.display_width(prefix)

    # Truncate name to fit in display columns, accounting for wide unicode and indicator space.
    name_pad_width = max(width - prefix_width - indicator_width, 0)
    display_name = truncate_name(name, name_pad_width)

    # Build draw commands: structure, icon, name, diagnostic marker, dirty marker, and git marker.
    guide_style = guide_draw_style(is_cursor, focused, theme)
    icon_style = icon_draw_style(icon_color, is_cursor, focused, theme)
    name_style = name_draw_style(tree_row, is_cursor, tree_row.active?, focused, theme)
    structure_width = Unicode.display_width(structure_prefix)

    draws = []
    draws = draws ++ [DisplayList.draw(row, col, structure_prefix, guide_style)]

    # Icon segment
    icon_col = col + structure_width
    draws = draws ++ [DisplayList.draw(row, icon_col, icon <> " ", icon_style)]

    # Name segment: pad to fill space between name and indicators
    name_col = col + prefix_width
    padded_name = Unicode.pad_display_trailing(display_name, name_pad_width)
    draws = draws ++ [DisplayList.draw(row, name_col, padded_name, name_style)]

    # Right-aligned indicators start here.
    indicator_col = col + width - indicator_width

    draws =
      draw_diagnostic_indicator(
        draws,
        tree_row.diagnostics,
        diagnostic_text,
        row,
        indicator_col,
        is_cursor,
        focused,
        theme
      )

    dirty_col = indicator_col + diagnostic_width
    draws = draw_dirty_indicator(draws, is_dirty, row, dirty_col, is_cursor, focused, theme)
    git_col = dirty_col + dirty_width
    draw_git_indicator(draws, file_git_status, row, git_col, is_cursor, focused, theme)
  end

  # ── Editing entry rendering ─────────────────────────────────────────────

  # Renders the inline editing entry with highlighted styling and a cursor indicator.
  # The editing row shows the entry's indent guides, a type indicator icon, the
  # current editing text, and a block cursor at the insertion point.
  @spec render_editing_entry(Row.t(), non_neg_integer(), map()) :: [DisplayList.draw()]
  defp render_editing_entry(tree_row, row, opts) do
    %{col_off: col, width: width, theme: theme} = opts
    editing = tree_row.editing

    # Type indicator: file icon for new file, folder icon for new folder,
    # the entry's own icon for rename
    {icon, _icon_color} =
      case editing.type do
        :new_file -> {"", 0x519ABA}
        :new_folder -> {@folder_open, 0x519ABA}
        :rename -> entry_icon(tree_row)
      end

    # Build the same structure columns as normal rows, but compact deep guides before they hide the edit text.
    disclosure = disclosure_marker(tree_row)
    fixed_prefix = disclosure <> icon <> " "

    guide_width =
      max(width - Unicode.display_width(fixed_prefix) - @minimum_editing_text_width, 0)

    guide_prefix = build_guides(tree_row.guides, guide_width)
    structure_prefix = guide_prefix <> disclosure
    structure_width = Unicode.display_width(structure_prefix)
    prefix = structure_prefix <> icon <> " "
    prefix_width = Unicode.display_width(prefix)

    # Editing text with cursor
    text = editing.text
    cursor_char = "▏"
    display_text = text <> cursor_char

    # Truncate to fit
    text_width = max(width - prefix_width, 0)
    display_text = Unicode.truncate_display_width(display_text, text_width)
    padded_text = Unicode.pad_display_trailing(display_text, text_width)

    # Editing row uses inverse video (selection highlight)
    editing_bg = theme.tree.dir_fg
    editing_fg = theme.tree.bg

    guide_style = Face.new(fg: editing_fg, bg: editing_bg)
    icon_style = Face.new(fg: editing_fg, bg: editing_bg)
    text_style = Face.new(fg: editing_fg, bg: editing_bg, bold: true)

    draws = []
    draws = draws ++ [DisplayList.draw(row, col, structure_prefix, guide_style)]

    icon_col = col + structure_width
    draws = draws ++ [DisplayList.draw(row, icon_col, icon <> " ", icon_style)]

    text_col = col + prefix_width
    draws = draws ++ [DisplayList.draw(row, text_col, padded_text, text_style)]

    draws
  end

  # ── Indent guides ──────────────────────────────────────────────────────

  @spec fixed_prefix_width(Row.t()) :: non_neg_integer()
  defp fixed_prefix_width(tree_row) do
    {icon, _icon_color} = entry_icon(tree_row)
    Unicode.display_width(disclosure_marker(tree_row) <> icon <> " ")
  end

  @spec row_prefix(Row.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {String.t(), String.t(), String.t(), non_neg_integer()}
  defp row_prefix(tree_row, row_width, indicator_width, minimum_name_width) do
    disclosure = disclosure_marker(tree_row)
    {icon, icon_color} = entry_icon(tree_row)
    fixed_prefix = disclosure <> icon <> " "

    guide_width =
      max(
        row_width - Unicode.display_width(fixed_prefix) - indicator_width - minimum_name_width,
        0
      )

    guide_prefix = build_guides(tree_row.guides, guide_width)
    structure_prefix = guide_prefix <> disclosure
    prefix = structure_prefix <> icon <> " "

    {prefix, structure_prefix, icon, icon_color}
  end

  @spec build_guides([boolean()], non_neg_integer()) :: String.t()
  defp build_guides(_ancestor_guides, 0), do: ""

  defp build_guides(ancestor_guides, max_width) do
    ancestor_guides
    |> guide_text()
    |> maybe_compact_guides(ancestor_guides, max_width)
  end

  @spec maybe_compact_guides(String.t(), [boolean()], non_neg_integer()) :: String.t()
  defp maybe_compact_guides(full_guides, ancestor_guides, max_width) do
    if Unicode.display_width(full_guides) <= max_width do
      full_guides
    else
      compact_guides(ancestor_guides, max_width)
    end
  end

  @spec compact_guides([boolean()], non_neg_integer()) :: String.t()
  defp compact_guides([], _max_width), do: ""
  defp compact_guides(_ancestor_guides, max_width) when max_width < 2, do: ""

  defp compact_guides(ancestor_guides, max_width) do
    suffix_width = max(max_width - Unicode.display_width(@guide_ellipsis), 0)

    suffix =
      ancestor_guides
      |> take_suffix_guides(div(suffix_width, 2))
      |> guide_text()

    Unicode.truncate_display_width(@guide_ellipsis <> suffix, max_width)
  end

  @spec take_suffix_guides([boolean()], non_neg_integer()) :: [boolean()]
  defp take_suffix_guides(_ancestor_guides, 0), do: []
  defp take_suffix_guides(ancestor_guides, count), do: Enum.take(ancestor_guides, -count)

  @spec guide_text([boolean()]) :: String.t()
  defp guide_text(ancestor_guides) do
    Enum.map_join(ancestor_guides, &guide_segment/1)
  end

  @spec guide_segment(boolean()) :: String.t()
  defp guide_segment(true), do: @guide_pipe
  defp guide_segment(false), do: @guide_blank

  @spec truncate_name(String.t(), non_neg_integer()) :: String.t()
  defp truncate_name(_name, 0), do: ""

  defp truncate_name(name, max_width) do
    if Unicode.display_width(name) <= max_width do
      name
    else
      truncate_name_middle(name, max_width)
    end
  end

  @spec truncate_name_middle(String.t(), non_neg_integer()) :: String.t()
  defp truncate_name_middle(name, 1), do: Unicode.truncate_display_width(name, 1)

  defp truncate_name_middle(name, max_width) do
    ellipsis_width = Unicode.display_width(@name_ellipsis)
    available_width = max(max_width - ellipsis_width, 0)
    suffix_width = suffix_width_for_name(name, available_width)
    prefix_width = available_width - suffix_width

    Unicode.truncate_display_width(name, prefix_width) <>
      @name_ellipsis <> trailing_display_width(name, suffix_width)
  end

  @spec suffix_width_for_name(String.t(), non_neg_integer()) :: non_neg_integer()
  defp suffix_width_for_name(_name, 0), do: 0

  defp suffix_width_for_name(name, available_width) do
    extension_width = name |> Path.extname() |> Unicode.display_width()
    available_width |> div(2) |> max(extension_width) |> min(available_width)
  end

  @spec trailing_display_width(String.t(), non_neg_integer()) :: String.t()
  defp trailing_display_width(_text, 0), do: ""

  defp trailing_display_width(text, max_width) do
    text
    |> String.graphemes()
    |> Enum.reverse()
    |> take_trailing_graphemes(max_width, 0, [])
  end

  @spec take_trailing_graphemes([String.t()], non_neg_integer(), non_neg_integer(), [String.t()]) ::
          String.t()
  defp take_trailing_graphemes([], _max_width, _width, acc), do: Enum.join(acc)

  defp take_trailing_graphemes([grapheme | rest], max_width, width, acc) do
    next_width = width + Unicode.grapheme_width(grapheme)

    if next_width > max_width do
      Enum.join(acc)
    else
      take_trailing_graphemes(rest, max_width, next_width, [grapheme | acc])
    end
  end

  @spec disclosure_marker(Row.t()) :: String.t()
  defp disclosure_marker(%Row{directory?: true, expanded?: true}), do: @disclosure_expanded
  defp disclosure_marker(%Row{directory?: true}), do: @disclosure_collapsed
  defp disclosure_marker(_tree_row), do: @disclosure_file

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

  @spec fit_indicators(
          String.t(),
          boolean(),
          Minga.Project.FileTree.GitStatus.file_status() | nil,
          non_neg_integer()
        ) :: {String.t(), boolean(), Minga.Project.FileTree.GitStatus.file_status() | nil}
  defp fit_indicators(diagnostic_text, dirty?, git_status, available_width) do
    {diagnostic_text, remaining_width} =
      fit_diagnostic_indicator(diagnostic_text, available_width)

    {dirty?, remaining_width} = fit_dirty_indicator(dirty?, remaining_width)
    {git_status, _remaining_width} = fit_git_indicator(git_status, remaining_width)
    {diagnostic_text, dirty?, git_status}
  end

  @spec fit_diagnostic_indicator(String.t(), non_neg_integer()) :: {String.t(), non_neg_integer()}
  defp fit_diagnostic_indicator("", available_width), do: {"", available_width}

  defp fit_diagnostic_indicator(text, available_width) do
    fitted = Unicode.truncate_display_width(text, available_width)
    {fitted, available_width - Unicode.display_width(fitted)}
  end

  @spec fit_dirty_indicator(boolean(), non_neg_integer()) :: {boolean(), non_neg_integer()}
  defp fit_dirty_indicator(true = _dirty?, available_width) when available_width >= 1,
    do: {true, available_width - 1}

  defp fit_dirty_indicator(_dirty?, available_width), do: {false, available_width}

  @spec fit_git_indicator(Minga.Project.FileTree.GitStatus.file_status() | nil, non_neg_integer()) ::
          {Minga.Project.FileTree.GitStatus.file_status() | nil, non_neg_integer()}
  defp fit_git_indicator(nil, available_width), do: {nil, available_width}

  defp fit_git_indicator(git_status, available_width) when available_width >= 2,
    do: {git_status, available_width - 2}

  defp fit_git_indicator(_git_status, available_width), do: {nil, available_width}

  @spec diagnostic_indicator_text(Diagnostics.t()) :: String.t()
  defp diagnostic_indicator_text(%Diagnostics{} = diagnostics) do
    case Diagnostics.highest_severity(diagnostics) do
      nil ->
        ""

      severity ->
        diagnostic_severity_icon(severity) <> diagnostic_count_suffix(diagnostics, severity)
    end
  end

  @spec diagnostic_count_suffix(Diagnostics.t(), Diagnostics.severity()) :: String.t()
  defp diagnostic_count_suffix(diagnostics, severity) do
    case Diagnostics.count_for(diagnostics, severity) do
      count when count > 9 -> "9+"
      count when count > 1 -> Integer.to_string(count)
      _count -> ""
    end
  end

  @spec diagnostic_severity_icon(Diagnostics.severity()) :: String.t()
  defp diagnostic_severity_icon(:error), do: "✖"
  defp diagnostic_severity_icon(:warning), do: "⚠"
  defp diagnostic_severity_icon(:info), do: "ℹ"
  defp diagnostic_severity_icon(:hint), do: "·"

  @spec draw_diagnostic_indicator(
          [DisplayList.draw()],
          Diagnostics.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          boolean(),
          Theme.t()
        ) :: [DisplayList.draw()]
  defp draw_diagnostic_indicator(
         draws,
         %Diagnostics{},
         "",
         _row,
         _col,
         _is_cursor,
         _focused,
         _theme
       ),
       do: draws

  defp draw_diagnostic_indicator(
         draws,
         %Diagnostics{} = diagnostics,
         text,
         row,
         col,
         is_cursor,
         focused,
         theme
       ) do
    case Diagnostics.highest_severity(diagnostics) do
      nil ->
        draws

      severity ->
        draws ++
          [
            DisplayList.draw(
              row,
              col,
              text,
              diagnostic_indicator_style(severity, is_cursor, focused, theme)
            )
          ]
    end
  end

  @spec diagnostic_indicator_style(Diagnostics.severity(), boolean(), boolean(), Theme.t()) ::
          Face.t()
  defp diagnostic_indicator_style(severity, is_cursor, focused, theme) do
    Face.new(
      fg: diagnostic_severity_color(severity, theme),
      bg: row_bg_color(is_cursor, focused, theme),
      bold: severity in [:error, :warning]
    )
  end

  @spec diagnostic_severity_color(Diagnostics.severity(), Theme.t()) :: non_neg_integer()
  defp diagnostic_severity_color(:error, theme), do: theme.gutter.error_fg
  defp diagnostic_severity_color(:warning, theme), do: theme.gutter.warning_fg
  defp diagnostic_severity_color(:info, theme), do: theme.gutter.info_fg
  defp diagnostic_severity_color(:hint, theme), do: theme.gutter.hint_fg

  @spec draw_dirty_indicator(
          [DisplayList.draw()],
          boolean(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          boolean(),
          Theme.t()
        ) :: [DisplayList.draw()]
  defp draw_dirty_indicator(draws, true = _is_dirty, row, col, is_cursor, focused, theme) do
    dirty_style = dirty_indicator_style(is_cursor, focused, theme)
    draws ++ [DisplayList.draw(row, col, "●", dirty_style)]
  end

  defp draw_dirty_indicator(draws, false = _is_dirty, _row, _col, _is_cursor, _focused, _theme),
    do: draws

  @spec dirty_indicator_style(boolean(), boolean(), Theme.t()) :: Face.t()
  defp dirty_indicator_style(is_cursor, focused, theme) do
    color = theme.tree.modified_fg || theme.tree.fg
    Face.new(fg: color, bg: row_bg_color(is_cursor, focused, theme), bold: true)
  end

  @spec draw_git_indicator(
          [DisplayList.draw()],
          Minga.Project.FileTree.GitStatus.file_status() | nil,
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          boolean(),
          Theme.t()
        ) :: [DisplayList.draw()]
  defp draw_git_indicator(draws, nil, _row, _col, _is_cursor, _focused, _theme), do: draws

  defp draw_git_indicator(draws, file_git_status, row, col, is_cursor, focused, theme) do
    git_symbol = " " <> Minga.Project.FileTree.GitStatus.symbol(file_git_status)
    git_style = git_indicator_style(file_git_status, is_cursor, focused, theme)
    draws ++ [DisplayList.draw(row, col, git_symbol, git_style)]
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

  @spec scroll_offset(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp scroll_offset(cursor, 0), do: cursor
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
  @spec tree_rect_from_workspace(map(), FileTreeState.t()) :: MingaEditor.WindowTree.rect() | nil
  defp tree_rect_from_workspace(%{viewport: %{rows: rows}}, %FileTreeState{
         tree: %Minga.Project.FileTree{width: tw}
       }) do
    {1, 0, tw, rows - 2}
  end

  defp tree_rect_from_workspace(_workspace, %FileTreeState{}), do: nil
end
