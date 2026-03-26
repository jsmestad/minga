defmodule Minga.Shell.Board.Renderer do
  @moduledoc """
  TUI renderer for The Board grid view.

  Draws card rectangles as bordered boxes with status badges, task
  descriptions, model names, and elapsed time. Uses the golden ratio
  layout from `Board.Layout` for card positioning.

  The renderer produces a list of `DisplayList.draw()` tuples that
  get composed into the splash layer of a `DisplayList.Frame`.
  """

  alias Minga.Editor.DisplayList
  alias Minga.Shell.Board.Card
  alias Minga.Shell.Board.Layout
  alias Minga.Shell.Board.State
  alias Minga.UI.Face

  # Box-drawing characters (Unicode)
  @tl "╭"
  @tr "╮"
  @bl "╰"
  @br "╯"
  @h "─"
  @v "│"

  # Status indicators
  @status_icons %{
    idle: "○",
    working: "●",
    iterating: "◉",
    needs_you: "◆",
    done: "✓",
    errored: "✗"
  }

  @doc """
  Renders the Board grid view as a list of DisplayList draws.

  Returns draws for: background fill, header, card borders, card
  content (status, task, model, time), and a focused card highlight.
  """
  @spec render(State.t(), pos_integer(), pos_integer(), Minga.UI.Theme.t()) ::
          [DisplayList.draw()]
  def render(%State{} = board, cols, rows, theme) do
    layout = Layout.compute(board, cols, rows)

    bg_face = Face.new(bg: theme.editor.bg)
    blank = String.duplicate(" ", cols)
    bg_draws = for row <- 0..(rows - 1), do: DisplayList.draw(row, 0, blank, bg_face)

    header_draws = render_header(board, cols, theme)

    card_draws =
      board
      |> State.sorted_cards()
      |> Enum.flat_map(fn card ->
        case Map.get(layout.card_rects, card.id) do
          nil -> []
          rect -> render_card(card, rect, card.id == board.focused_card, theme)
        end
      end)

    empty_draws =
      if State.card_count(board) == 0 do
        render_empty_prompt(cols, rows, theme)
      else
        []
      end

    footer_draws = render_footer(cols, rows, board, theme)

    bg_draws ++ header_draws ++ card_draws ++ empty_draws ++ footer_draws
  end

  # ── Header ─────────────────────────────────────────────────────────────

  @spec render_header(State.t(), pos_integer(), Minga.UI.Theme.t()) :: [DisplayList.draw()]
  defp render_header(board, cols, theme) do
    face = Face.new(fg: theme.editor.fg, bg: theme.editor.bg, bold: true)
    dim_face = Face.new(fg: 0x5C6370, bg: theme.editor.bg)
    title = " ◇ The Board"
    count = State.card_count(board)
    count_text = "  #{count} card#{if count != 1, do: "s", else: ""} "

    [
      DisplayList.draw(0, 0, title, face),
      DisplayList.draw(0, String.length(title), pad_right(count_text, max(cols - String.length(title), 0)), dim_face)
    ]
  end

  # ── Card rendering ─────────────────────────────────────────────────────

  @spec render_card(Card.t(), Layout.rect(), boolean(), Minga.UI.Theme.t()) ::
          [DisplayList.draw()]
  defp render_card(card, {row, col, width, height}, focused, theme) do
    border_face =
      if focused do
        Face.new(fg: theme.editor.cursorline_bg || 0x61AFEF, bg: theme.editor.bg)
      else
        Face.new(fg: 0x5C6370, bg: theme.editor.bg)
      end

    content_face = Face.new(fg: theme.editor.fg, bg: theme.editor.bg)
    dim_face = Face.new(fg: 0x5C6370, bg: theme.editor.bg)
    status_face = status_face(card.status, theme)

    # inner_width: card width minus border chars (│ + space on each side = 4 cells)
    inner_width = max(width - 4, 1)
    content_start = row + 1
    content_end = max(row + height - 2, content_start)

    # Build draws list (prepend, reverse at end)
    draws = []

    # Top border
    draws =
      if height >= 1 do
        top_inner = String.duplicate(@h, max(width - 2, 0))
        [DisplayList.draw(row, col, @tl <> top_inner <> @tr, border_face) | draws]
      else
        draws
      end

    # Row 1: Status badge + elapsed time
    draws =
      if content_start <= content_end do
        icon = Map.get(@status_icons, card.status, "○")
        label = if Card.you_card?(card), do: "You", else: status_label(card.status)
        elapsed = format_elapsed(card.created_at)

        line = build_two_column_line(icon <> " " <> label, elapsed, inner_width)
        [DisplayList.draw(content_start, col, @v <> " " <> line <> " " <> @v, status_face) | draws]
      else
        draws
      end

    # Row 2: Task description (bold)
    draws =
      if content_start + 1 <= content_end do
        task = pad_right(card.task, inner_width)
        [DisplayList.draw(content_start + 1, col, @v <> " " <> task <> " " <> @v, content_face) | draws]
      else
        draws
      end

    # Row 3+: blank separator rows
    draws =
      Enum.reduce((content_start + 2)..max(content_end - 1, content_start + 1)//1, draws, fn r, acc ->
        blank_line = String.duplicate(" ", inner_width)
        [DisplayList.draw(r, col, @v <> " " <> blank_line <> " " <> @v, content_face) | acc]
      end)

    # Last content row: Model + file count (footer)
    draws =
      if content_end > content_start + 1 do
        model = card.model || ""
        files = if card.recent_files != [], do: "#{length(card.recent_files)} files", else: ""

        line = build_two_column_line(model, files, inner_width)
        [DisplayList.draw(content_end, col, @v <> " " <> line <> " " <> @v, dim_face) | draws]
      else
        draws
      end

    # Fill remaining content rows with empty bordered lines
    filled_rows = min(4, max(content_end - content_start + 1, 0))

    draws =
      Enum.reduce((content_start + filled_rows)..content_end//1, draws, fn r, acc ->
        blank_line = String.duplicate(" ", inner_width)
        line = @v <> " " <> blank_line <> " " <> @v
        [DisplayList.draw(r, col, line, border_face) | acc]
      end)

    # Bottom border
    draws =
      if height >= 2 do
        bottom_inner = String.duplicate(@h, max(width - 2, 0))
        [DisplayList.draw(row + height - 1, col, @bl <> bottom_inner <> @br, border_face) | draws]
      else
        draws
      end

    Enum.reverse(draws)
  end

  # ── Footer (keyboard hints) ──────────────────────────────────────────

  @spec render_footer(pos_integer(), pos_integer(), State.t(), Minga.UI.Theme.t()) ::
          [DisplayList.draw()]
  defp render_footer(cols, rows, board, theme) do
    face = Face.new(fg: 0x5C6370, bg: theme.editor.bg)
    key_face = Face.new(fg: theme.editor.fg, bg: theme.editor.bg, bold: true)

    card_count = State.card_count(board)
    focused = State.focused(board)
    focused_label = if focused, do: " #{focused.task}", else: ""

    # Build hint segments: key = description
    hints = [
      {"↑↓←→", "navigate"},
      {"Enter", "zoom in"},
      {"n", "new agent"},
      {"q", "back to editor"}
    ]

    # Render as: ↑↓←→ navigate  Enter zoom in  n new agent  q back
    hint_parts =
      Enum.map(hints, fn {key, desc} ->
        [{key, key_face}, {" #{desc}  ", face}]
      end)
      |> List.flatten()

    # Left side: card count
    left = " #{card_count} card#{if card_count != 1, do: "s", else: ""}#{focused_label}"
    left_draw = DisplayList.draw(rows - 1, 0, pad_right(left, cols), face)

    # Right side: hints (draw on second-to-last row if space)
    hint_row = rows - 2

    hint_draws =
      if hint_row > 2 do
        {draws, _col} =
          Enum.reduce(hint_parts, {[], 2}, fn {text, f}, {acc, c} ->
            {[DisplayList.draw(hint_row, c, text, f) | acc], c + String.length(text)}
          end)

        draws
      else
        []
      end

    [left_draw | hint_draws]
  end

  # ── Empty prompt ───────────────────────────────────────────────────────

  @spec render_empty_prompt(pos_integer(), pos_integer(), Minga.UI.Theme.t()) ::
          [DisplayList.draw()]
  defp render_empty_prompt(cols, rows, theme) do
    face = Face.new(fg: 0x5C6370, bg: theme.editor.bg)
    bold_face = Face.new(fg: theme.editor.fg, bg: theme.editor.bg, bold: true)

    center_row = div(rows, 2)

    [
      centered_draw(center_row - 1, cols, "◇ The Board", bold_face),
      centered_draw(center_row + 1, cols, "Press  n  to dispatch a new agent", face),
      centered_draw(center_row + 2, cols, "Press  SPC t b  to return to editor", face)
    ]
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @spec status_face(Card.status(), Minga.UI.Theme.t()) :: Face.t()
  defp status_face(:idle, theme), do: Face.new(fg: 0x5C6370, bg: theme.editor.bg)
  defp status_face(:working, theme), do: Face.new(fg: 0x98C379, bg: theme.editor.bg)
  defp status_face(:iterating, theme), do: Face.new(fg: 0x98C379, bg: theme.editor.bg)
  defp status_face(:needs_you, theme), do: Face.new(fg: 0xE5C07B, bg: theme.editor.bg)
  defp status_face(:done, theme), do: Face.new(fg: 0x61AFEF, bg: theme.editor.bg)
  defp status_face(:errored, theme), do: Face.new(fg: 0xE06C75, bg: theme.editor.bg)
  defp status_face(_, theme), do: Face.new(fg: 0x5C6370, bg: theme.editor.bg)

  @spec status_label(Card.status()) :: String.t()
  defp status_label(:idle), do: "Idle"
  defp status_label(:working), do: "Working"
  defp status_label(:iterating), do: "Iterating"
  defp status_label(:needs_you), do: "Needs you"
  defp status_label(:done), do: "Done"
  defp status_label(:errored), do: "Errored"
  defp status_label(_), do: ""

  @spec format_elapsed(DateTime.t() | nil) :: String.t()
  defp format_elapsed(nil), do: ""

  defp format_elapsed(created_at) do
    seconds = DateTime.diff(DateTime.utc_now(), created_at, :second)
    cond_elapsed(seconds)
  end

  defp cond_elapsed(s) when s < 60, do: "#{s}s"
  defp cond_elapsed(s) when s < 3600, do: "#{div(s, 60)}m"
  defp cond_elapsed(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  @spec pad_right(String.t(), pos_integer()) :: String.t()
  defp pad_right(text, width) do
    len = String.length(text)

    if len > width do
      String.slice(text, 0, max(width - 1, 0)) <> "…"
    else
      text <> String.duplicate(" ", max(width - len, 0))
    end
  end

  @spec build_two_column_line(String.t(), String.t(), pos_integer()) :: String.t()
  defp build_two_column_line(left, right, width) do
    left_len = String.length(left)
    right_len = String.length(right)
    gap = max(width - left_len - right_len, 1)

    total = left <> String.duplicate(" ", gap) <> right
    total_len = String.length(total)

    if total_len > width do
      # Truncate left side, keep right visible
      avail = max(width - right_len - 2, 0)
      String.slice(left, 0, avail) <> "… " <> right
    else
      total <> String.duplicate(" ", max(width - total_len, 0))
    end
  end

  @spec centered_draw(non_neg_integer(), pos_integer(), String.t(), Face.t()) ::
          DisplayList.draw()
  defp centered_draw(row, cols, text, face) do
    text_len = String.length(text)
    col = max(div(cols - text_len, 2), 0)
    DisplayList.draw(row, col, text, face)
  end
end
