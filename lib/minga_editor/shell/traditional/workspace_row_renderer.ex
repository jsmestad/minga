defmodule MingaEditor.Shell.Traditional.WorkspaceRowRenderer do
  @moduledoc """
  Renders the TUI workspace row from shared workspace chrome state.

  The BEAM owns all workspace semantics. The Zig TUI receives only cell draws and layout regions, so it never infers workspace state from labels, paths, or tab order.
  """

  alias Minga.Core.Face
  alias Minga.Core.Unicode
  alias MingaEditor.DisplayList
  alias MingaEditor.UI.Theme
  alias MingaEditor.Workspace.ChromeState
  alias MingaEditor.Workspace.ChromeState.WorkspaceSummary

  @type click_region ::
          {row :: non_neg_integer(), col_start :: non_neg_integer(), col_end :: non_neg_integer(),
           command :: atom() | {:workspace_goto, non_neg_integer()}}

  @overflow_left "◂"
  @overflow_right "▸"

  @doc "Renders one workspace row and click regions."
  @spec render(non_neg_integer(), pos_integer(), ChromeState.t(), Theme.t()) ::
          {[DisplayList.draw()], [click_region()]}
  def render(row, cols, %ChromeState{} = chrome_state, %Theme{} = theme) do
    colors = colors(theme)
    segments = build_segments(chrome_state, colors)
    active_id = chrome_state.active_workspace_id

    if segments_width(segments) <= cols do
      render_segments(row, cols, segments, colors)
    else
      render_overflow(row, cols, segments, active_id, colors)
    end
  end

  @doc "Returns whether the workspace row should be shown for this chrome state."
  @spec relevant?(ChromeState.t()) :: boolean()
  def relevant?(%ChromeState{} = chrome_state) do
    length(chrome_state.workspaces) > 1 or chrome_state.draft_count > 0 or
      chrome_state.conflict_count > 0 or chrome_state.attention_count > 0 or
      chrome_state.background_count > 0
  end

  @typep segment :: %{
           id: non_neg_integer(),
           text: String.t(),
           width: non_neg_integer(),
           fg: non_neg_integer(),
           bg: non_neg_integer(),
           command: atom() | {:workspace_goto, non_neg_integer()}
         }

  @spec build_segments(ChromeState.t(), map()) :: [segment()]
  defp build_segments(%ChromeState{} = chrome_state, colors) do
    Enum.map(chrome_state.workspaces, fn workspace ->
      active? = workspace.id == chrome_state.active_workspace_id
      text = workspace_text(workspace, active?)

      {fg, bg} =
        if active?,
          do: {colors.active_fg, colors.active_bg},
          else: {colors.inactive_fg, colors.inactive_bg}

      %{
        id: workspace.id,
        text: text,
        width: Unicode.display_width(text),
        fg: fg,
        bg: bg,
        command: workspace_command(workspace)
      }
    end)
  end

  @spec workspace_command(WorkspaceSummary.t()) :: {:workspace_goto, non_neg_integer()}
  defp workspace_command(%WorkspaceSummary{id: id}), do: {:workspace_goto, id}

  @spec workspace_text(WorkspaceSummary.t(), boolean()) :: String.t()
  defp workspace_text(%WorkspaceSummary{} = workspace, active?) do
    active_marker = if active?, do: "*", else: ""
    badges = badge_text(workspace)
    count = if workspace.tab_count > 0, do: " [#{workspace.tab_count}]", else: ""

    " #{workspace.icon} #{workspace.label}#{active_marker} #{status_glyph(workspace.status)}#{badges}#{count} "
  end

  @spec badge_text(WorkspaceSummary.t()) :: String.t()
  defp badge_text(%WorkspaceSummary{} = workspace) do
    [
      badge("C", workspace.conflict_count),
      badge("D", workspace.draft_count),
      if(workspace.attention?, do: " !", else: ""),
      badge("bg", workspace.running_background_count)
    ]
    |> Enum.join("")
  end

  @spec badge(String.t(), non_neg_integer()) :: String.t()
  defp badge(_label, 0), do: ""
  defp badge(label, count), do: " #{label}#{count}"

  @spec status_glyph(WorkspaceSummary.status()) :: String.t()
  defp status_glyph(:thinking), do: "⟳"
  defp status_glyph(:tool_executing), do: "⚡"
  defp status_glyph(:error), do: "✗"
  defp status_glyph(:plan), do: "✎"
  defp status_glyph(:needs_review), do: "!"
  defp status_glyph(:done), do: "✓"
  defp status_glyph(_status), do: "○"

  @spec segments_width([segment()]) :: non_neg_integer()
  defp segments_width(segments), do: Enum.reduce(segments, 0, &(&1.width + &2))

  @spec render_segments(non_neg_integer(), pos_integer(), [segment()], map()) ::
          {[DisplayList.draw()], [click_region()]}
  defp render_segments(row, cols, segments, colors) do
    {draws, regions, col} = emit_segments(row, segments, 0, cols)
    fill = fill_draw(row, col, cols, colors.bg)
    {draws ++ fill, regions}
  end

  @spec render_overflow(non_neg_integer(), pos_integer(), [segment()], non_neg_integer(), map()) ::
          {[DisplayList.draw()], [click_region()]}
  defp render_overflow(row, cols, segments, active_id, colors) do
    left_w = Unicode.display_width(@overflow_left)
    right_w = Unicode.display_width(@overflow_right)
    usable = max(cols - left_w - right_w, 1)
    {visible_segments, hidden_left?, hidden_right?} = visible_window(segments, active_id, usable)
    {draws, regions, col} = emit_segments(row, visible_segments, left_w, cols - right_w)

    left_text = if hidden_left?, do: @overflow_left, else: " "
    right_text = if hidden_right?, do: @overflow_right, else: " "

    left_draws = [
      DisplayList.draw(row, 0, left_text, Face.new(fg: colors.separator_fg, bg: colors.bg))
    ]

    right_draws = [
      DisplayList.draw(
        row,
        cols - right_w,
        right_text,
        Face.new(fg: colors.separator_fg, bg: colors.bg)
      )
    ]

    fill = fill_draw(row, col, cols - right_w, colors.bg)

    {left_draws ++ draws ++ right_draws ++ fill, regions}
  end

  @spec visible_window([segment()], non_neg_integer(), pos_integer()) ::
          {[segment()], boolean(), boolean()}
  defp visible_window(segments, active_id, usable) do
    active_index = Enum.find_index(segments, &(&1.id == active_id)) || 0
    active = Enum.at(segments, active_index)

    {left, right} =
      segments
      |> Enum.with_index()
      |> Enum.split_with(fn {_segment, idx} -> idx < active_index end)

    left = Enum.map(left, fn {segment, _idx} -> segment end)
    right = Enum.map(right, fn {segment, _idx} -> segment end)

    {visible_left, visible_right} =
      expand_window(Enum.reverse(left), right, max(usable - active.width, 0), [], [])

    visible = Enum.reverse(visible_left) ++ [active] ++ visible_right
    hidden_left? = length(visible_left) < length(left)
    hidden_right? = length(visible_right) < length(right)
    {visible, hidden_left?, hidden_right?}
  end

  @spec expand_window([segment()], [segment()], non_neg_integer(), [segment()], [segment()]) ::
          {[segment()], [segment()]}
  defp expand_window([], [], _remaining, left_acc, right_acc),
    do: {left_acc, Enum.reverse(right_acc)}

  defp expand_window([left | left_rest], right, remaining, left_acc, right_acc)
       when left.width <= remaining do
    expand_window_right(left_rest, right, remaining - left.width, [left | left_acc], right_acc)
  end

  defp expand_window(_left, right, remaining, left_acc, right_acc) do
    expand_window_right([], right, remaining, left_acc, right_acc)
  end

  @spec expand_window_right([segment()], [segment()], non_neg_integer(), [segment()], [segment()]) ::
          {[segment()], [segment()]}
  defp expand_window_right(left, [right | right_rest], remaining, left_acc, right_acc)
       when right.width <= remaining do
    expand_window(left, right_rest, remaining - right.width, left_acc, [right | right_acc])
  end

  defp expand_window_right(_left, _right, _remaining, left_acc, right_acc) do
    {left_acc, Enum.reverse(right_acc)}
  end

  @spec emit_segments(non_neg_integer(), [segment()], non_neg_integer(), non_neg_integer()) ::
          {[DisplayList.draw()], [click_region()], non_neg_integer()}
  defp emit_segments(row, segments, start_col, max_col) do
    Enum.reduce(segments, {[], [], start_col}, fn segment, {draws, regions, col} ->
      emit_segment(row, segment, draws, regions, col, max_col)
    end)
  end

  @spec emit_segment(
          non_neg_integer(),
          segment(),
          [DisplayList.draw()],
          [click_region()],
          non_neg_integer(),
          non_neg_integer()
        ) :: {[DisplayList.draw()], [click_region()], non_neg_integer()}
  defp emit_segment(_row, _segment, draws, regions, col, max_col) when col >= max_col do
    {draws, regions, col}
  end

  defp emit_segment(row, segment, draws, regions, col, max_col) do
    available = max_col - col
    text = Unicode.truncate_display_width(segment.text, available)
    width = Unicode.display_width(text)
    draw = DisplayList.draw(row, col, text, Face.new(fg: segment.fg, bg: segment.bg))
    region = {row, col, col + width - 1, segment.command}
    {draws ++ [draw], [region | regions], col + width}
  end

  @spec fill_draw(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          [DisplayList.draw()]
  defp fill_draw(_row, col, cols, _bg) when col >= cols, do: []

  defp fill_draw(row, col, cols, bg) do
    [DisplayList.draw(row, col, String.duplicate(" ", cols - col), Face.new(bg: bg))]
  end

  @spec colors(Theme.t()) :: map()
  defp colors(%Theme{} = theme) do
    tab_bar = theme.tab_bar

    %{
      active_fg: tab_bar.active_fg,
      active_bg: tab_bar.active_bg,
      inactive_fg: tab_bar.inactive_fg,
      inactive_bg: tab_bar.inactive_bg,
      separator_fg: tab_bar.separator_fg,
      bg: tab_bar.bg
    }
  end
end
