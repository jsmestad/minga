defmodule MingaEditor.Shell.Traditional.GitStatusRenderer do
  @moduledoc """
  TUI renderer for the git status panel sidebar.

  Renders section headers (Staged, Changes, Untracked, Conflicts) with file
  rows inside each section. Shared git status data provides repo and file
  status; TUI-only shell state provides cursor and collapsed-section state.

  Follows the same `[DisplayList.draw()]` pattern as `TreeRenderer`.
  """

  alias Minga.Core.Face
  alias Minga.Git.StatusEntry
  alias MingaEditor.DisplayList
  alias MingaEditor.Layout
  alias MingaEditor.Shell.Traditional.GitStatus.TuiState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Theme

  @type state :: EditorState.t() | MingaEditor.RenderPipeline.Input.t()

  @section_labels %{
    conflicts: "Conflicts",
    staged: "Staged",
    changes: "Changes",
    untracked: "Untracked"
  }

  @section_icons %{
    conflicts: "!",
    staged: "✓",
    changes: "~",
    untracked: "?"
  }

  @doc """
  Renders the git status panel into the given sidebar rect.

  Returns an empty list when no panel is active or the layout did not reserve a sidebar rect.
  """
  @spec render(state(), Layout.rect() | nil) :: [DisplayList.draw()]
  def render(_state, nil), do: []

  def render(state, rect) do
    case EditorState.git_status_panel(state) do
      nil -> []
      panel -> do_render(panel, tui_state(state), rect, state.theme)
    end
  end

  @spec do_render(map(), TuiState.t(), Layout.rect(), Theme.t()) :: [DisplayList.draw()]
  defp do_render(panel, tui, {row_off, col_off, width, height}, theme) do
    entries = Map.get(panel, :entries) || []
    flat_entries = TuiState.flat_entries(tui, entries)
    render_panel(panel, tui, flat_entries, row_off, col_off, width, height, theme)
  end

  @spec tui_state(state()) :: TuiState.t()
  defp tui_state(%{shell_state: %{git_status_tui_state: %TuiState{} = tui}}), do: tui
  defp tui_state(_state), do: TuiState.new()

  @spec render_panel(
          map(),
          TuiState.t(),
          [TuiState.flat_entry()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Theme.t()
        ) :: [DisplayList.draw()]
  defp render_panel(panel, tui, flat_entries, row_off, col_off, width, height, theme) do
    branch = Map.get(panel, :branch) || ""
    ahead = Map.get(panel, :ahead) || 0
    behind = Map.get(panel, :behind) || 0

    stash_count = Map.get(panel, :stash_count) || 0
    header_text = header_text(branch, ahead, behind, stash_count)
    header_display = String.slice(header_text, 0, width) |> String.pad_trailing(width)

    header = [
      DisplayList.draw(
        row_off,
        col_off,
        header_display,
        Face.new(fg: theme.tree.header_fg, bg: theme.tree.header_bg, bold: true)
      )
    ]

    content_rows = height - 1
    scroll_offset = scroll_offset(tui.cursor_index, content_rows)

    entry_draws =
      flat_entries
      |> Enum.with_index()
      |> Enum.drop(scroll_offset)
      |> Enum.take(content_rows)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{entry, global_idx}, screen_row} ->
        row = row_off + 1 + screen_row
        is_cursor = global_idx == tui.cursor_index
        render_flat_entry(entry, row, col_off, width, is_cursor, theme)
      end)

    visible_count = max(min(length(flat_entries) - scroll_offset, content_rows), 0)
    blank_draws = render_blanks(visible_count, content_rows, row_off + 1, col_off, width, theme)
    sep_col = col_off + width
    sep_draws = render_separator(sep_col, row_off, height, theme)

    header ++ entry_draws ++ blank_draws ++ sep_draws
  end

  @spec render_flat_entry(
          TuiState.flat_entry(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          Theme.t()
        ) :: [DisplayList.draw()]
  defp render_flat_entry({:section_header, section, count}, row, col_off, width, is_cursor, theme) do
    icon = Map.get(@section_icons, section, " ")
    label = Map.get(@section_labels, section, to_string(section))
    text = " #{icon} #{label} (#{count})"
    display = String.slice(text, 0, width) |> String.pad_trailing(width)

    bg = if is_cursor, do: theme.tree.cursor_bg, else: theme.tree.header_bg
    fg = theme.tree.header_fg

    [DisplayList.draw(row, col_off, display, Face.new(fg: fg, bg: bg, bold: true))]
  end

  defp render_flat_entry({:file, _section, entry}, row, col_off, width, is_cursor, theme) do
    status_char = status_character(entry.status)
    status_fg = status_color(entry, theme)
    filename = Path.basename(entry.path)
    dir = Path.dirname(entry.path)

    prefix = "  #{status_char} "
    prefix_len = String.length(prefix)

    name_text =
      if dir != "." do
        "#{filename} #{dir}/"
      else
        filename
      end

    available = max(width - prefix_len, 0)
    name_display = String.slice(name_text, 0, available) |> String.pad_trailing(available)

    bg = if is_cursor, do: theme.tree.cursor_bg, else: nil
    name_fg = if is_cursor, do: theme.tree.active_fg, else: theme.tree.fg

    [
      DisplayList.draw(row, col_off, prefix, Face.new(fg: status_fg, bg: bg)),
      DisplayList.draw(row, col_off + prefix_len, name_display, Face.new(fg: name_fg, bg: bg))
    ]
  end

  @spec header_text(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          String.t()
  defp header_text(branch, ahead, behind, stash_count) do
    badge =
      case {ahead, behind} do
        {0, 0} -> ""
        {a, 0} -> " ↑#{a}"
        {0, b} -> " ↓#{b}"
        {a, b} -> " ↑#{a}↓#{b}"
      end

    stash_badge = if stash_count > 0, do: " Stashes: #{stash_count}", else: ""

    "  #{branch}#{badge}#{stash_badge}"
  end

  @spec status_character(atom()) :: String.t()
  defp status_character(:added), do: "A"
  defp status_character(:modified), do: "M"
  defp status_character(:deleted), do: "D"
  defp status_character(:renamed), do: "R"
  defp status_character(:copied), do: "C"
  defp status_character(:untracked), do: "?"
  defp status_character(:conflict), do: "!"
  defp status_character(_), do: " "

  @spec status_color(StatusEntry.t(), Theme.t()) :: non_neg_integer()
  defp status_color(%{status: :added}, theme), do: theme.git.added_fg
  defp status_color(%{status: :modified}, theme), do: theme.git.modified_fg
  defp status_color(%{status: :deleted}, theme), do: theme.git.deleted_fg
  defp status_color(%{status: :renamed}, theme), do: theme.git.modified_fg
  defp status_color(%{status: :conflict}, theme), do: theme.gutter.error_fg
  defp status_color(%{status: :untracked}, theme), do: theme.gutter.fg
  defp status_color(_, theme), do: theme.tree.fg

  @spec scroll_offset(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp scroll_offset(_cursor, content_rows) when content_rows <= 0, do: 0

  defp scroll_offset(cursor, content_rows) do
    max(cursor - div(content_rows, 2), 0)
  end

  @spec render_blanks(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Theme.t()
        ) :: [DisplayList.draw()]
  defp render_blanks(visible, total, start_row, col_off, width, theme) do
    if visible < total do
      for row <- (start_row + visible)..(start_row + total - 1) do
        DisplayList.draw(row, col_off, String.duplicate(" ", width), Face.new(bg: theme.tree.bg))
      end
    else
      []
    end
  end

  @spec render_separator(non_neg_integer(), non_neg_integer(), non_neg_integer(), Theme.t()) :: [
          DisplayList.draw()
        ]
  defp render_separator(col, row_off, height, theme) do
    sep_face = Face.new(fg: theme.tree.separator_fg)

    for row <- row_off..(row_off + height - 1) do
      DisplayList.draw(row, col, "│", sep_face)
    end
  end
end
