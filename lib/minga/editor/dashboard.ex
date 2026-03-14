defmodule Minga.Editor.Dashboard do
  @moduledoc """
  Dashboard home screen renderer.

  Renders the editor's landing page when no file buffers are open. Shows
  an ASCII pretzel logo, quick-action shortcuts, recent files, and a
  version string. All content is horizontally centered.

  This is a pure rendering module: it takes dimensions, theme, and state,
  and returns a list of `DisplayList.draw()` tuples. No side effects.
  """

  alias Minga.Editor.DisplayList
  alias Minga.Theme
  alias Minga.Theme.Dashboard, as: DashTheme

  @typedoc "Command dispatched when a dashboard item is selected."
  @type command :: atom() | {:open_file, String.t()}

  @typedoc "Dashboard item: an action the user can select."
  @type item :: %{
          label: String.t(),
          shortcut: String.t(),
          command: command()
        }

  @typedoc "Dashboard state: cursor position and computed items."
  @type state :: %{
          cursor: non_neg_integer(),
          items: [item()]
        }

  @doc "Returns a fresh dashboard state with quick actions and recent files."
  @spec new_state([String.t()]) :: state()
  def new_state(recent_files \\ []) do
    items = quick_actions() ++ recent_file_items(recent_files)
    %{cursor: 0, items: items}
  end

  @doc "Moves the dashboard cursor up, wrapping at the top."
  @spec cursor_up(state()) :: state()
  def cursor_up(%{cursor: cursor, items: items} = state) do
    count = length(items)

    new_cursor =
      case count do
        0 -> 0
        _ -> rem(cursor - 1 + count, count)
      end

    %{state | cursor: new_cursor}
  end

  @doc "Moves the dashboard cursor down, wrapping at the bottom."
  @spec cursor_down(state()) :: state()
  def cursor_down(%{cursor: cursor, items: items} = state) do
    count = length(items)

    new_cursor =
      case count do
        0 -> 0
        _ -> rem(cursor + 1, count)
      end

    %{state | cursor: new_cursor}
  end

  @doc "Returns the command for the currently selected item, or nil if no items."
  @spec selected_command(state()) :: command() | nil
  def selected_command(%{cursor: cursor, items: items}) do
    case Enum.at(items, cursor) do
      nil -> nil
      item -> item.command
    end
  end

  @doc """
  Renders the dashboard as a list of display list draws.

  Lays out the pretzel logo, quick actions, recent files heading, recent
  file entries, and a bottom-pinned version string, all horizontally
  centered in the given `width` x `height` area.
  """
  @spec render(pos_integer(), pos_integer(), Theme.t(), state()) :: [DisplayList.draw()]
  def render(width, height, theme, dash_state) do
    dt = Theme.dashboard_theme(theme)

    # Background fill
    blank = String.duplicate(" ", width)
    bg_draws = for row <- 0..(height - 1), do: DisplayList.draw(row, 0, blank, bg: dt.bg)

    # Build content sections
    logo_lines = logo()
    logo_height = length(logo_lines)

    action_items = quick_actions()
    recent_items = dash_state.items -- action_items
    has_recent = recent_items != []

    # Calculate content height; skip logo if terminal is too small
    min_actions_height =
      1 + length(action_items) + 1 + if(has_recent, do: 1 + length(recent_items) + 1, else: 1) + 1

    show_logo = height >= logo_height + 2 + min_actions_height

    content_height =
      if(show_logo, do: logo_height + 1, else: 0) + min_actions_height

    start_row = max(div(height - content_height, 2), 0)
    row = start_row

    # Logo (skip if terminal is too short)
    logo_draws =
      if show_logo do
        draws = render_logo(logo_lines, row, width, dt)
        row = row + logo_height

        title = "M I N G A"
        title_draw = centered_draw(row, width, title, fg: dt.heading_fg, bg: dt.bg, bold: true)
        row = row + 2
        {draws ++ [title_draw], row}
      else
        {[], row}
      end

    {logo_draw_list, row} = logo_draws

    # Quick actions heading
    actions_heading =
      centered_draw(row, width, "Quick Actions", fg: dt.heading_fg, bg: dt.bg, bold: true)

    row = row + 1

    # Quick action items
    {action_draws, row} = render_items(action_items, 0, dash_state.cursor, row, width, dt)

    row = row + 1

    # Recent files section
    {recent_draws, _row} =
      if has_recent do
        heading =
          centered_draw(row, width, "Recent Files", fg: dt.heading_fg, bg: dt.bg, bold: true)

        row = row + 1
        offset = length(action_items)
        {items_draws, row} = render_items(recent_items, offset, dash_state.cursor, row, width, dt)
        {[heading | items_draws], row}
      else
        {[], row}
      end

    # Version pinned to bottom
    version_text = "Minga v#{Minga.version()}"
    version_draw = centered_draw(height - 1, width, version_text, fg: dt.muted_fg, bg: dt.bg)

    all_draws =
      bg_draws ++
        logo_draw_list ++
        [actions_heading] ++ action_draws ++ recent_draws ++ [version_draw]

    # Clamp: discard any draws outside the visible area
    Enum.filter(all_draws, fn {row, _col, _text, _style} -> row >= 0 and row < height end)
  end

  # ── Logo ──────────────────────────────────────────────────────────────────

  @spec logo() :: [String.t()]
  defp logo do
    [
      "            .::^^^^::.",
      "         .^^          ^^.",
      "       .^   .::^^^^::.   ^.",
      "      :   .^          ^.   :",
      "     :  .^   .:::::.   ^.  :",
      "    :  :   .^       ^.   :  :",
      "   :  :  .^           ^.  :  :",
      "   :  :  :             :  :  :",
      "   :  :  :             :  :  :",
      "    :  :  ^.         .^  :  :",
      "     :  ^.  ^.     .^  .^  :",
      "      :   ^.  ^. .^  .^   :",
      "       ^.   ^.  Y  .^   .^",
      "         ^.  .^   ^.  .^",
      "          .^^ .^.^ ^^.",
      "        .^   .^   ^.   ^.",
      "       :   .^       ^.   :",
      "      :  .^           ^.  :",
      "      :  :             :  :",
      "       :  ^.         .^  :",
      "        ^.  ^::...::^  .^",
      "          ^^.        .^^",
      "             ^^^^^^^^"
    ]
  end

  @spec render_logo([String.t()], non_neg_integer(), pos_integer(), DashTheme.t()) ::
          [DisplayList.draw()]
  defp render_logo(lines, start_row, width, dt) do
    max_line_width = lines |> Enum.map(&String.length/1) |> Enum.max()

    Enum.with_index(lines, fn line, idx ->
      pad = max(div(width - max_line_width, 2), 0)
      DisplayList.draw(start_row + idx, pad, line, fg: dt.logo_fg, bg: dt.bg)
    end)
  end

  # ── Items ─────────────────────────────────────────────────────────────────

  @spec quick_actions() :: [item()]
  defp quick_actions do
    [
      %{label: "Find file", shortcut: "SPC f f", command: :find_file},
      %{label: "Recent files", shortcut: "SPC f r", command: :recent_files},
      %{label: "New buffer", shortcut: "SPC b N", command: :new_buffer},
      %{label: "Agent session", shortcut: "SPC a a", command: :activate_agent},
      %{label: "Switch project", shortcut: "SPC p p", command: :find_project}
    ]
  end

  @spec recent_file_items([String.t()]) :: [item()]
  defp recent_file_items(recent_files) do
    recent_files
    |> Enum.take(10)
    |> Enum.map(fn path ->
      %{label: path, shortcut: "", command: {:open_file, path}}
    end)
  end

  @spec render_items(
          [item()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          DashTheme.t()
        ) ::
          {[DisplayList.draw()], non_neg_integer()}
  defp render_items(items, index_offset, cursor, start_row, width, dt) do
    draws =
      Enum.with_index(items, fn item, idx ->
        global_idx = index_offset + idx
        row = start_row + idx
        active = global_idx == cursor

        render_item(item, row, width, active, dt)
      end)
      |> List.flatten()

    {draws, start_row + length(items)}
  end

  @spec render_item(item(), non_neg_integer(), pos_integer(), boolean(), DashTheme.t()) ::
          [DisplayList.draw()]
  defp render_item(item, row, width, active, dt) do
    shortcut_part =
      if item.shortcut != "" do
        "  #{item.shortcut}  "
      else
        "  "
      end

    text = "#{shortcut_part}#{item.label}"
    pad = max(div(width - String.length(text), 2), 0)

    # Build the full padded line for active highlight
    if active do
      highlight_width = String.length(text) + 4
      highlight_pad = max(div(width - highlight_width, 2), 0)
      highlight_bg = String.duplicate(" ", highlight_width)

      [
        DisplayList.draw(row, highlight_pad, highlight_bg, bg: dt.item_active_bg),
        if item.shortcut != "" do
          DisplayList.draw(row, pad, "  #{item.shortcut}",
            fg: dt.shortcut_fg,
            bg: dt.item_active_bg,
            bold: true
          )
        else
          DisplayList.draw(row, pad, " ", bg: dt.item_active_bg)
        end,
        DisplayList.draw(
          row,
          pad + String.length(shortcut_part),
          item.label,
          fg: dt.item_fg,
          bg: dt.item_active_bg
        )
      ]
      |> List.flatten()
    else
      draws = [
        if item.shortcut != "" do
          DisplayList.draw(row, pad, "  #{item.shortcut}", fg: dt.shortcut_fg, bg: dt.bg)
        else
          DisplayList.draw(row, pad, " ", bg: dt.bg)
        end,
        DisplayList.draw(
          row,
          pad + String.length(shortcut_part),
          item.label,
          fg: dt.item_fg,
          bg: dt.bg
        )
      ]

      List.flatten(draws)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  @spec centered_draw(non_neg_integer(), pos_integer(), String.t(), keyword()) ::
          DisplayList.draw()
  defp centered_draw(row, width, text, style) do
    pad = max(div(width - String.length(text), 2), 0)
    DisplayList.draw(row, pad, text, style)
  end
end
