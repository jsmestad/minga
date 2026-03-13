defmodule Minga.Editor.TabBarRenderer do
  @moduledoc """
  Renders the tab bar at the top of the screen.

  Produces a list of draw commands for row 0 and a list of click regions
  for mouse hit-testing, following the same segment pattern as the
  modeline renderer.

  Uses Powerline slant separators between tabs and handles overflow when
  tabs exceed the terminal width by scrolling to keep the active tab
  visible.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Devicon
  alias Minga.Editor.DisplayList
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Filetype
  alias Minga.Theme

  @typedoc "A clickable region: column range mapping to a command."
  @type click_region ::
          {col_start :: non_neg_integer(), col_end :: non_neg_integer(), command :: atom()}

  # Powerline separators (right-pointing triangle)
  @sep_right "\u{E0B0}"
  @overflow_left "\u{25C2} "
  @overflow_right " \u{25B8}"

  @doc """
  Renders the tab bar at the given row.

  Returns `{draw_commands, click_regions}`.
  """
  @spec render(non_neg_integer(), pos_integer(), TabBar.t(), Theme.t()) ::
          {[DisplayList.draw()], [click_region()]}
  def render(row, cols, %TabBar{} = tb, %Theme{} = theme) do
    colors = tab_bar_colors(theme)

    # Build logical segments for each tab (text, colors, tab id, width)
    segments = build_segments(tb, colors)

    # Calculate total width to detect overflow
    total_width = Enum.reduce(segments, 0, fn seg, acc -> acc + seg.width + 1 end)

    if total_width <= cols do
      render_segments(row, cols, segments, colors)
    else
      render_overflow(row, cols, segments, tb.active_id, colors)
    end
  end

  # ── Segment building ───────────────────────────────────────────────────────

  @typep segment :: %{
           text: String.t(),
           fg: Theme.color(),
           bg: Theme.color(),
           tab_id: pos_integer(),
           width: non_neg_integer()
         }

  @spec build_segments(TabBar.t(), map()) :: [segment()]
  defp build_segments(tb, colors) do
    tb.tabs
    |> Enum.with_index(1)
    |> Enum.map(fn {tab, position} ->
      is_active = tab.id == tb.active_id

      {fg, bg} =
        if is_active do
          {colors.active_fg, colors.active_bg}
        else
          {colors.inactive_fg, colors.inactive_bg}
        end

      icon = tab_icon(tab)
      label = tab_label(tab)
      dirty = tab_dirty_marker(tab, colors)
      status = agent_status_indicator(tab)
      attention = if tab.attention and not is_active, do: " !", else: ""
      number = tab_number(position)

      text = " #{number}#{icon} #{label}#{dirty}#{status}#{attention} "
      width = Unicode.display_width(text)

      # Override color for attention tabs (not active) to make the badge visible
      fg = if tab.attention and not is_active, do: colors.attention_fg, else: fg

      %{text: text, fg: fg, bg: bg, tab_id: tab.id, width: width}
    end)
  end

  # ── Normal rendering (fits in terminal width) ──────────────────────────────

  @spec render_segments(non_neg_integer(), pos_integer(), [segment()], map()) ::
          {[DisplayList.draw()], [click_region()]}
  defp render_segments(row, cols, segments, colors) do
    {draws, regions, col} = emit_segments(row, 0, segments, colors)

    # Fill remaining width
    fill = fill_draws(row, col, cols, colors.bg)
    {draws ++ fill, regions}
  end

  # ── Overflow rendering (tabs exceed terminal width) ─────────────────────────

  @spec render_overflow(non_neg_integer(), pos_integer(), [segment()], pos_integer(), map()) ::
          {[DisplayList.draw()], [click_region()]}
  defp render_overflow(row, cols, segments, active_id, colors) do
    left_indicator_w = String.length(@overflow_left)
    right_indicator_w = String.length(@overflow_right)
    usable = cols - left_indicator_w - right_indicator_w

    # Find the scroll offset that keeps the active tab visible.
    # Walk segments left to right, accumulating width. The scroll offset
    # is the first pixel column that's visible.
    {scroll_offset, _} = find_scroll_offset(segments, active_id, usable)

    # Render visible segments with clipping
    {draws, regions, end_col} =
      emit_segments_clipped(row, left_indicator_w, segments, colors, scroll_offset, usable)

    # Left overflow indicator
    show_left = scroll_offset > 0

    left_draws =
      if show_left do
        [{row, 0, @overflow_left, [fg: colors.separator_fg, bg: colors.bg]}]
      else
        []
      end

    # Right overflow indicator
    show_right = end_col > left_indicator_w + usable

    right_draws =
      if show_right do
        [
          {row, cols - right_indicator_w, @overflow_right,
           [fg: colors.separator_fg, bg: colors.bg]}
        ]
      else
        []
      end

    fill =
      fill_draws(
        row,
        min(end_col, left_indicator_w + usable),
        cols - right_indicator_w,
        colors.bg
      )

    {left_draws ++ draws ++ right_draws ++ fill, regions}
  end

  @spec find_scroll_offset([segment()], pos_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp find_scroll_offset(segments, active_id, usable) do
    # Walk segments to find the active tab's logical start column and width.
    # Each segment occupies seg.width + 1 cols (content + separator).
    {_pos, active_start, active_width} =
      Enum.reduce(segments, {0, 0, 0}, fn seg, {pos, a_start, a_width} ->
        seg_total = seg.width + 1

        if seg.tab_id == active_id do
          {pos + seg_total, pos, seg_total}
        else
          {pos + seg_total, a_start, a_width}
        end
      end)

    # Center the active tab in the visible area
    active_mid = active_start + div(active_width, 2)
    ideal_offset = max(active_mid - div(usable, 2), 0)

    total = Enum.reduce(segments, 0, fn seg, acc -> acc + seg.width + 1 end)
    max_offset = max(total - usable, 0)

    {min(ideal_offset, max_offset), active_start + active_width}
  end

  # ── Shared emit helpers ────────────────────────────────────────────────────

  @spec emit_segments(non_neg_integer(), non_neg_integer(), [segment()], map()) ::
          {[DisplayList.draw()], [click_region()], non_neg_integer()}
  defp emit_segments(row, start_col, segments, colors) do
    Enum.reduce(segments, {[], [], start_col}, fn seg, {draws, regions, col} ->
      # Tab content
      tab_draw = {row, col, seg.text, [fg: seg.fg, bg: seg.bg]}
      tab_end = col + seg.width

      # Click region
      region = {col, tab_end - 1, :"tab_goto_#{seg.tab_id}"}

      # Powerline separator
      {sep_draws, sep_end} = powerline_sep(row, tab_end, seg.bg, colors.bg, colors)

      {draws ++ [tab_draw | sep_draws], [region | regions], sep_end}
    end)
  end

  @spec emit_segments_clipped(
          non_neg_integer(),
          non_neg_integer(),
          [segment()],
          map(),
          non_neg_integer(),
          pos_integer()
        ) :: {[DisplayList.draw()], [click_region()], non_neg_integer()}
  defp emit_segments_clipped(row, screen_start, segments, colors, scroll_offset, usable) do
    screen_end = screen_start + usable

    Enum.reduce(segments, {[], [], 0}, fn seg, {draws, regions, logical_col} ->
      seg_end = logical_col + seg.width + 1
      screen_col = screen_start + logical_col - scroll_offset

      if seg_end <= scroll_offset or screen_col >= screen_end do
        {draws, regions, seg_end}
      else
        tab_draw = {row, screen_col, seg.text, [fg: seg.fg, bg: seg.bg]}
        tab_screen_end = screen_col + seg.width
        region = clipped_region(screen_col, tab_screen_end, screen_start, screen_end, seg.tab_id)
        {sep_draws, _} = powerline_sep(row, tab_screen_end, seg.bg, colors.bg, colors)

        {draws ++ [tab_draw | sep_draws], maybe_add_region(regions, region), seg_end}
      end
    end)
  end

  @spec maybe_add_region([click_region()], click_region() | nil) :: [click_region()]
  defp maybe_add_region(regions, nil), do: regions
  defp maybe_add_region(regions, region), do: [region | regions]

  @spec clipped_region(integer(), integer(), integer(), integer(), pos_integer()) ::
          click_region() | nil
  defp clipped_region(screen_col, tab_screen_end, screen_start, screen_end, tab_id) do
    if tab_screen_end > screen_start and screen_col < screen_end do
      {max(screen_col, screen_start), min(tab_screen_end - 1, screen_end - 1),
       :"tab_goto_#{tab_id}"}
    else
      nil
    end
  end

  @spec powerline_sep(non_neg_integer(), non_neg_integer(), Theme.color(), Theme.color(), map()) ::
          {[DisplayList.draw()], non_neg_integer()}
  defp powerline_sep(row, col, left_bg, right_bg, _colors) do
    sep_draw = {row, col, @sep_right, [fg: left_bg, bg: right_bg]}
    {[sep_draw], col + 1}
  end

  @spec fill_draws(non_neg_integer(), non_neg_integer(), non_neg_integer(), Theme.color()) ::
          [DisplayList.draw()]
  defp fill_draws(_row, col, max_col, _bg) when col >= max_col, do: []

  defp fill_draws(row, col, max_col, bg) do
    fill = String.duplicate(" ", max_col - col)
    [{row, col, fill, [bg: bg]}]
  end

  # ── Tab content helpers ────────────────────────────────────────────────────

  @spec tab_number(pos_integer()) :: String.t()
  defp tab_number(n) when n >= 1 and n <= 9, do: "#{n}:"
  defp tab_number(_), do: ""

  @spec tab_icon(Tab.t()) :: String.t()
  defp tab_icon(%Tab{kind: :agent}), do: Devicon.icon(:agent)
  defp tab_icon(%Tab{kind: :file, label: label}), do: Devicon.icon(Filetype.detect(label))

  @spec tab_label(Tab.t()) :: String.t()
  defp tab_label(%Tab{label: ""}), do: "[No Name]"
  defp tab_label(%Tab{label: label}), do: label

  @spec tab_dirty_marker(Tab.t(), map()) :: String.t()
  defp tab_dirty_marker(%Tab{kind: :file} = tab, _colors) do
    buf = tab_active_buffer(tab)

    if is_pid(buf) and Process.alive?(buf) and BufferServer.dirty?(buf), do: " ●", else: ""
  end

  defp tab_dirty_marker(_, _), do: ""

  @spec agent_status_indicator(Tab.t()) :: String.t()
  defp agent_status_indicator(%Tab{kind: :agent, agent_status: :thinking}), do: " \u{25CF}"
  defp agent_status_indicator(%Tab{kind: :agent, agent_status: :tool_executing}), do: " \u{2699}"
  defp agent_status_indicator(%Tab{kind: :agent, agent_status: :error}), do: " \u{2717}"
  defp agent_status_indicator(_), do: ""

  @spec tab_active_buffer(Tab.t()) :: pid() | nil
  defp tab_active_buffer(%Tab{context: %{buffers: %{active: buf}}}), do: buf
  defp tab_active_buffer(_), do: nil

  @spec tab_bar_colors(Theme.t()) :: map()
  defp tab_bar_colors(%Theme{tab_bar: %Theme.TabBar{} = tb}), do: Map.from_struct(tb)

  defp tab_bar_colors(%Theme{editor: editor, modeline: ml}) do
    %{
      active_fg: editor.fg,
      active_bg: editor.bg,
      inactive_fg: ml.bar_fg,
      inactive_bg: ml.bar_bg,
      separator_fg: ml.bar_fg,
      modified_fg: 0xDA8548,
      attention_fg: 0xFF6C6B,
      bg: ml.bar_bg
    }
  end
end
