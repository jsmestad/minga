defmodule Minga.Agent.View.DirectoryRenderer do
  @moduledoc """
  Renders a directory listing in the preview pane.

  Shows a header with the directory path, then a scrollable list of
  entries with file/directory icons. Directories are visually distinct
  with a folder icon and trailing slash.
  """

  alias Minga.Editor.DisplayList
  alias Minga.Theme
  alias Minga.Face

  @typedoc "A draw rectangle: {row_offset, col_offset, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @doc "Renders a directory listing into draw commands."
  @spec render(rect(), String.t(), [String.t()], non_neg_integer(), boolean(), Theme.t()) ::
          [DisplayList.draw()]
  def render({row_off, col_off, width, height}, path, entries, scroll_offset, auto_follow, theme) do
    at = Theme.agent_theme(theme)
    content_start = row_off + 1
    content_rows = max(height - 1, 1)
    total = length(entries)
    max_scroll = max(total - content_rows, 0)
    scroll = if auto_follow, do: max_scroll, else: min(scroll_offset, max_scroll)

    header = render_header(row_off, col_off, width, path, at)
    entry_cmds = render_entries(content_start, col_off, width, content_rows, entries, scroll, at)
    fill_cmds = render_fill(content_start, col_off, width, content_rows, entries, scroll, at)

    [header | entry_cmds] ++ fill_cmds
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec render_header(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          String.t(),
          Theme.Agent.t()
        ) ::
          DisplayList.draw()
  defp render_header(row, col, width, path, at) do
    text = String.pad_trailing(" 📂 #{path}", width)
    DisplayList.draw(row, col, text, Face.new(fg: at.header_fg, bg: at.header_bg))
  end

  @spec render_entries(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          [String.t()],
          non_neg_integer(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
  defp render_entries(start_row, col, width, content_rows, entries, scroll, at) do
    visible = Enum.slice(entries, scroll, content_rows)
    blank = String.duplicate(" ", width)

    visible
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} ->
      row = start_row + idx
      is_dir = String.ends_with?(entry, "/")
      icon = if is_dir, do: "📁 ", else: "📄 "
      fg = if is_dir, do: at.header_fg, else: at.text_fg
      display = String.slice("  #{icon}#{entry}", 0, width)

      [
        DisplayList.draw(row, col, blank, Face.new(bg: at.panel_bg)),
        DisplayList.draw(row, col, display, Face.new(fg: fg, bg: at.panel_bg))
      ]
    end)
  end

  @spec render_fill(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          [String.t()],
          non_neg_integer(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
  defp render_fill(start_row, col, width, content_rows, entries, scroll, at) do
    visible_count = length(Enum.slice(entries, scroll, content_rows))

    if visible_count < content_rows do
      blank = String.duplicate(" ", width)

      for r <- (start_row + visible_count)..(start_row + content_rows - 1) do
        DisplayList.draw(r, col, blank, Face.new(bg: at.panel_bg))
      end
    else
      []
    end
  end
end
