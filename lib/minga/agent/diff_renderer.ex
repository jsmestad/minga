defmodule Minga.Agent.DiffRenderer do
  @moduledoc """
  Renders a unified diff view in the file viewer panel.

  When a `DiffReview` is active, this module replaces the normal buffer
  rendering with a colored diff display showing added, removed, and
  context lines with gutter markers for resolution status.
  """

  alias Minga.Agent.DiffReview
  alias Minga.Editor.DisplayList
  alias Minga.Theme

  @typedoc "A draw command for the display list."
  @type draw :: DisplayList.draw()

  @doc """
  Renders the diff view into the given rect.

  Returns a list of draw commands. The rect is `{row_offset, col_offset, width, height}`.
  """
  @spec render(
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
          DiffReview.t(),
          Theme.t()
        ) :: [draw()]
  def render({row_off, col_off, width, height}, review, theme) do
    header_cmds = render_header(row_off, col_off, width, review, theme)

    content_start = row_off + 1
    content_height = max(height - 1, 1)

    display_lines = DiffReview.to_display_lines(review)

    # Determine scroll position: center current hunk in view
    scroll = scroll_for_current_hunk(display_lines, review, content_height)

    visible_lines = Enum.drop(display_lines, scroll) |> Enum.take(content_height)

    gutter_w = 3
    content_w = max(width - gutter_w, 1)
    content_col = col_off + gutter_w

    line_cmds =
      visible_lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, screen_row} ->
        abs_row = content_start + screen_row
        render_diff_line(abs_row, col_off, gutter_w, content_col, content_w, line, review, theme)
      end)

    # Fill remaining rows with blank
    rendered_count = length(visible_lines)

    fill_cmds =
      if rendered_count < content_height do
        blank = String.duplicate(" ", width)

        for row <- (content_start + rendered_count)..(content_start + content_height - 1) do
          DisplayList.draw(row, col_off, blank)
        end
      else
        []
      end

    header_cmds ++ line_cmds ++ fill_cmds
  end

  # ── Header ──────────────────────────────────────────────────────────────────

  @spec render_header(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          DiffReview.t(),
          Theme.t()
        ) :: [draw()]
  defp render_header(row, col, width, review, theme) do
    {added, removed} = DiffReview.summary(review)
    filename = Path.basename(review.path)
    dir = Path.dirname(review.path)

    text = "Diff: #{filename} (#{dir})  +#{added}, -#{removed}"
    padded = String.pad_trailing(String.slice(text, 0, width), width)

    at = theme.agent
    [DisplayList.draw(row, col, padded, fg: at.header_fg, bg: at.header_bg, bold: true)]
  end

  # ── Line rendering ─────────────────────────────────────────────────────────

  @spec render_diff_line(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          DiffReview.diff_line(),
          DiffReview.t(),
          Theme.t()
        ) :: [draw()]

  defp render_diff_line(
         row,
         gutter_col,
         gutter_w,
         content_col,
         content_w,
         {text, type, hunk_idx},
         review,
         theme
       ) do
    git = theme.git
    at = theme.agent
    is_current = hunk_idx != nil and hunk_idx == review.current_hunk_index

    {gutter_char, fg, bg} = line_style(type, hunk_idx, review, git, at, is_current)

    # Resolution marker in gutter
    resolution_marker =
      if hunk_idx != nil do
        case DiffReview.resolution_at(review, hunk_idx) do
          :accepted -> "✓"
          :rejected -> "✗"
          nil -> "?"
        end
      else
        " "
      end

    gutter_text = String.pad_trailing("#{resolution_marker}#{gutter_char}", gutter_w)
    content_text = String.slice(text, 0, content_w) |> String.pad_trailing(content_w)

    gutter_cmd = DisplayList.draw(row, gutter_col, gutter_text, fg: fg, bg: bg)
    content_cmd = DisplayList.draw(row, content_col, content_text, fg: fg, bg: bg)

    highlight_cmds =
      if is_current and hunk_idx != nil do
        # Subtle left-border highlight for current hunk
        [
          DisplayList.draw(row, gutter_col, resolution_marker,
            fg: theme.editor.fg,
            bg: bg,
            bold: true
          )
        ]
      else
        []
      end

    [gutter_cmd, content_cmd | highlight_cmds]
  end

  @spec line_style(
          :context | :added | :removed | :hunk_header,
          non_neg_integer() | nil,
          DiffReview.t(),
          Theme.Git.t(),
          Theme.Agent.t(),
          boolean()
        ) :: {String.t(), Theme.color(), Theme.color() | nil}

  defp line_style(:hunk_header, _hunk_idx, _review, _git, at, _is_current) do
    {"@", at.thinking_fg, at.panel_bg}
  end

  defp line_style(:context, _hunk_idx, _review, _git, at, _is_current) do
    {" ", at.text_fg, at.panel_bg}
  end

  defp line_style(:added, _hunk_idx, _review, git, at, _is_current) do
    {"+", git.added_fg, at.panel_bg}
  end

  defp line_style(:removed, _hunk_idx, _review, git, at, _is_current) do
    {"-", git.deleted_fg, at.panel_bg}
  end

  # ── Scrolling ───────────────────────────────────────────────────────────────

  @spec scroll_for_current_hunk([DiffReview.diff_line()], DiffReview.t(), pos_integer()) ::
          non_neg_integer()
  defp scroll_for_current_hunk(display_lines, review, content_height) do
    # Find the first display line belonging to the current hunk
    target_idx =
      Enum.find_index(display_lines, fn {_text, type, hunk_idx} ->
        hunk_idx == review.current_hunk_index and type in [:hunk_header, :added, :removed]
      end)

    case target_idx do
      nil -> 0
      idx -> max(0, idx - div(content_height, 3))
    end
  end
end
