defmodule Minga.Agent.View.ShellRenderer do
  @moduledoc """
  Renders shell command output in the preview pane.

  Shows a header bar with the command and status indicator, followed by
  scrollable output content with line numbers.
  """

  alias Minga.Editor.DisplayList
  alias Minga.Face
  alias Minga.Theme

  @typedoc "Bounding rectangle: `{row, col, width, height}`."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc "Shell status."
  @type status :: :running | :done | :error

  @doc "Renders shell command output within the given rectangle."
  @spec render(
          rect(),
          String.t(),
          String.t(),
          status(),
          non_neg_integer(),
          boolean(),
          non_neg_integer(),
          Theme.t()
        ) :: [DisplayList.draw()]
  def render(
        {row_off, col_off, width, height},
        command,
        output,
        status,
        scroll_offset,
        auto_follow,
        spinner_frame,
        theme
      ) do
    at = Theme.agent_theme(theme)

    header = render_header(row_off, col_off, width, command, status, spinner_frame, at)
    content_start = row_off + 1
    content_height = max(height - 1, 1)

    content =
      render_output(
        content_start,
        col_off,
        width,
        content_height,
        output,
        scroll_offset,
        auto_follow,
        at
      )

    header ++ content
  end

  @spec render_header(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          String.t(),
          status(),
          non_neg_integer(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
  defp render_header(row, col, width, command, status, spinner_frame, at) do
    {icon, icon_fg} = status_indicator(status, spinner_frame)
    truncated_cmd = String.slice(command, 0, max(width - 10, 10))
    text = String.pad_trailing(" #{icon} $ #{truncated_cmd} ", width)

    [DisplayList.draw(row, col, text, Face.new(fg: icon_fg, bg: at.header_bg))]
  end

  @spec render_output(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          String.t(),
          non_neg_integer(),
          boolean(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
  defp render_output(start_row, col, width, height, output, scroll_offset, auto_follow, at) do
    lines = String.split(output, "\n")
    total = length(lines)
    max_scroll = max(total - height, 0)
    scroll_clamped = if auto_follow, do: max_scroll, else: min(scroll_offset, max_scroll)

    visible = Enum.slice(lines, scroll_clamped, height)

    gutter_w = gutter_width(total)
    content_w = max(width - gutter_w, 1)
    blank = String.duplicate(" ", width)

    line_cmds =
      visible
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, idx} ->
        row = start_row + idx
        line_num = scroll_clamped + idx + 1
        gutter_text = String.pad_leading("#{line_num}", gutter_w - 1) <> " "
        content_text = String.slice(line, 0, content_w)

        [
          DisplayList.draw(row, col, blank, Face.new(bg: at.panel_bg)),
          DisplayList.draw(row, col, gutter_text, Face.new(fg: at.tool_border, bg: at.panel_bg)),
          DisplayList.draw(
            row,
            col + gutter_w,
            content_text,
            Face.new(fg: at.text_fg, bg: at.panel_bg)
          )
        ]
      end)

    fill_cmds = fill_remaining_rows(start_row, col, width, height, length(visible), at)
    line_cmds ++ fill_cmds
  end

  @spec fill_remaining_rows(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          Theme.Agent.t()
        ) :: [DisplayList.draw()]
  defp fill_remaining_rows(_start_row, _col, _width, height, rendered, _at)
       when rendered >= height,
       do: []

  defp fill_remaining_rows(start_row, col, width, height, rendered, at) do
    blank = String.duplicate(" ", width)

    for r <- (start_row + rendered)..(start_row + height - 1) do
      DisplayList.draw(r, col, blank, Face.new(bg: at.panel_bg))
    end
  end

  @spinner_chars ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @spec status_indicator(status(), non_neg_integer()) :: {String.t(), non_neg_integer()}
  defp status_indicator(:running, frame) do
    char = Enum.at(@spinner_chars, rem(frame, length(@spinner_chars)))
    # Use a bright color for running; we don't have access to the theme's thinking color
    # directly here but we can return a generic bright value and let the caller override.
    {char, 6}
  end

  defp status_indicator(:done, _frame), do: {"✓", 2}
  defp status_indicator(:error, _frame), do: {"✗", 1}

  @spec gutter_width(non_neg_integer()) :: pos_integer()
  defp gutter_width(total_lines) when total_lines < 100, do: 4
  defp gutter_width(total_lines) when total_lines < 1000, do: 5
  defp gutter_width(total_lines) when total_lines < 10_000, do: 6
  defp gutter_width(_), do: 7
end
