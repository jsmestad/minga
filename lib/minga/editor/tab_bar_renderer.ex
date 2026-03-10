defmodule Minga.Editor.TabBarRenderer do
  @moduledoc """
  Renders the tab bar at the top of the screen.

  Produces a list of draw commands for row 0 and a list of click regions
  for mouse hit-testing, following the same segment pattern as the
  modeline renderer.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.DisplayList
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Theme

  @typedoc "A clickable region: column range mapping to a command."
  @type click_region ::
          {col_start :: non_neg_integer(), col_end :: non_neg_integer(), command :: atom()}

  @separator " │ "
  @agent_icon "󰚩 "
  @file_icon " "

  @doc """
  Renders the tab bar at the given row.

  Returns `{draw_commands, click_regions}`.
  """
  @spec render(non_neg_integer(), pos_integer(), TabBar.t(), Theme.t()) ::
          {[DisplayList.draw()], [click_region()]}
  def render(row, cols, %TabBar{} = tb, %Theme{} = theme) do
    tab_colors = tab_bar_colors(theme)
    active_id = tb.active_id

    # Build segments for each tab
    {draws, regions, final_col} =
      Enum.reduce(tb.tabs, {[], [], 0}, fn tab, {draws_acc, regions_acc, col} ->
        is_active = tab.id == active_id
        {tab_draws, tab_regions, end_col} = render_tab(row, col, tab, is_active, tab_colors)

        # Separator after this tab (unless we're past screen width)
        {sep_draws, sep_end} =
          if end_col < cols do
            sep_text = @separator
            sep_w = String.length(sep_text)

            sep_draw =
              {row, end_col, sep_text, [fg: tab_colors.separator_fg, bg: tab_colors.bg]}

            {[sep_draw], end_col + sep_w}
          else
            {[], end_col}
          end

        {draws_acc ++ tab_draws ++ sep_draws, regions_acc ++ tab_regions, sep_end}
      end)

    # Fill remaining width with background
    fill_draws =
      if final_col < cols do
        fill_width = cols - final_col
        fill = String.duplicate(" ", fill_width)
        [{row, final_col, fill, [bg: tab_colors.bg]}]
      else
        []
      end

    {draws ++ fill_draws, regions}
  end

  @spec render_tab(
          non_neg_integer(),
          non_neg_integer(),
          Tab.t(),
          boolean(),
          map()
        ) :: {[DisplayList.draw()], [click_region()], non_neg_integer()}
  defp render_tab(row, col, tab, is_active, colors) do
    {fg, bg} =
      if is_active do
        {colors.active_fg, colors.active_bg}
      else
        {colors.inactive_fg, colors.inactive_bg}
      end

    icon = tab_icon(tab)
    label = tab_label(tab)
    dirty = tab_dirty_marker(tab)

    text = " #{icon}#{label}#{dirty} "
    width = String.length(text)

    draw = {row, col, text, [fg: fg, bg: bg]}
    end_col = col + width

    # Click region: command to switch to this tab
    command = :"tab_goto_#{tab.id}"
    region = {col, end_col - 1, command}

    {[draw], [region], end_col}
  end

  @spec tab_icon(Tab.t()) :: String.t()
  defp tab_icon(%Tab{kind: :agent}), do: @agent_icon
  defp tab_icon(%Tab{kind: :file}), do: @file_icon

  @spec tab_label(Tab.t()) :: String.t()
  defp tab_label(%Tab{label: ""}), do: "[No Name]"
  defp tab_label(%Tab{label: label}), do: label

  @spec tab_dirty_marker(Tab.t()) :: String.t()
  defp tab_dirty_marker(%Tab{kind: :file, context: %{active_buffer: buf}}) when is_pid(buf) do
    if Process.alive?(buf) and BufferServer.dirty?(buf), do: " ●", else: ""
  end

  defp tab_dirty_marker(_), do: ""

  @spec tab_bar_colors(Theme.t()) :: map()
  defp tab_bar_colors(%Theme{tab_bar: %Theme.TabBar{} = tb}), do: Map.from_struct(tb)

  defp tab_bar_colors(%Theme{editor: editor, modeline: ml}) do
    # Fallback for themes without tab_bar colors
    %{
      active_fg: editor.fg,
      active_bg: editor.bg,
      inactive_fg: ml.bar_fg,
      inactive_bg: ml.bar_bg,
      separator_fg: ml.bar_fg,
      modified_fg: 0xDA8548,
      bg: ml.bar_bg
    }
  end
end
