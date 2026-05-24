defmodule MingaEditor.Shell.Traditional.SidebarRenderer do
  @moduledoc """
  Renders extension-owned sidebar snapshots into the TUI sidebar rect.

  This renderer consumes cached snapshot rows from `MingaEditor.Extension.Sidebar`. It never calls extension render callbacks in the frame loop.
  """

  alias Minga.Core.Face
  alias Minga.Core.Unicode
  alias MingaEditor.DisplayList
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Extension.Sidebar.Snapshot
  alias MingaEditor.Layout

  @typedoc "Editor or render-pipeline state with theme data."
  @type state :: map()

  @doc "Returns true when a registered left sidebar is visible."
  @spec visible?() :: boolean()
  def visible?, do: Sidebar.active_left() != nil

  @doc "Renders the first visible registered left sidebar."
  @spec render(state(), Layout.rect() | nil) :: [DisplayList.draw()]
  def render(_state, nil), do: []

  def render(state, rect) do
    case Sidebar.active_left() do
      nil -> []
      sidebar -> render_sidebar(state, rect, sidebar)
    end
  end

  @spec render_sidebar(state(), Layout.rect(), Sidebar.entry()) :: [DisplayList.draw()]
  defp render_sidebar(state, {row, col, width, height}, %{
         display_name: title,
         snapshot: %Snapshot{} = snapshot
       }) do
    theme = Map.get(state, :theme)
    header_face = Face.new(fg: theme.tree.header_fg, bg: theme.tree.header_bg, bold: true)
    normal_face = Face.new(fg: theme.tree.fg, bg: theme.tree.bg)
    selected_face = Face.new(fg: theme.tree.active_fg, bg: theme.tree.cursor_bg)
    muted_face = Face.new(fg: theme.tree.separator_fg, bg: theme.tree.bg)

    header = [DisplayList.draw(row, col, fit(title, width), header_face)]

    content =
      snapshot
      |> snapshot_lines()
      |> Enum.take(max(height - 1, 0))
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        face = if Map.get(line, :selected?, false), do: selected_face, else: normal_face
        face = if Map.get(line, :muted?, false), do: muted_face, else: face
        DisplayList.draw(row + index + 1, col, fit(row_text(line), width), face)
      end)

    header ++ content
  end

  @spec snapshot_lines(Snapshot.t()) :: [Snapshot.row()]
  defp snapshot_lines(%Snapshot{status: :loading, message: message}),
    do: [%{text: message || "Loading…", muted?: true}]

  defp snapshot_lines(%Snapshot{status: :error, message: message}),
    do: [%{text: message || "Sidebar failed", muted?: true}]

  defp snapshot_lines(%Snapshot{status: :empty, message: message}),
    do: [%{text: message || "No items", muted?: true}]

  defp snapshot_lines(%Snapshot{rows: rows}), do: rows

  @spec row_text(Snapshot.row()) :: String.t()
  defp row_text(row) do
    indent = String.duplicate("  ", Map.get(row, :indent, 0))
    icon = icon_prefix(Map.get(row, :icon))
    text = Map.get(row, :text, "")
    badge = badge_suffix(Map.get(row, :badge), Map.get(row, :diagnostic_count, 0))
    indent <> icon <> text <> badge
  end

  @spec icon_prefix(String.t() | nil) :: String.t()
  defp icon_prefix(nil), do: ""
  defp icon_prefix(""), do: ""
  defp icon_prefix(icon), do: icon <> " "

  @spec badge_suffix(String.t() | nil, non_neg_integer()) :: String.t()
  defp badge_suffix(nil, 0), do: ""
  defp badge_suffix(nil, count), do: " " <> Integer.to_string(count)
  defp badge_suffix(badge, _count), do: " " <> badge

  @spec fit(String.t(), non_neg_integer()) :: String.t()
  defp fit(text, width) when width <= 0, do: text

  defp fit(text, width) do
    if Unicode.display_width(text) <= width do
      String.pad_trailing(text, width)
    else
      text |> String.slice(0, max(width - 1, 0)) |> Kernel.<>("…")
    end
  end
end
