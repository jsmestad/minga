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
  alias MingaEditor.Shell.Traditional.TreeRenderer

  @typedoc "Editor or render-pipeline state with theme data."
  @type state :: map()

  @doc "Returns the first visible registered left sidebar for the given state, if any."
  @spec active_sidebar(state()) :: Sidebar.entry() | nil
  def active_sidebar(state), do: Sidebar.active_left(Sidebar.table_for(state))

  @doc "Renders a registered sidebar entry into the given rect."
  @spec render(state(), Layout.rect() | nil, Sidebar.entry()) :: [DisplayList.draw()]
  def render(_state, nil, _sidebar), do: []
  def render(state, _rect, %{semantic_kind: "file_tree"}), do: TreeRenderer.render(state)

  def render(state, rect, %{semantic_kind: "git_status"}),
    do: render_git_status_sidebar(state, rect)

  def render(state, rect, sidebar), do: render_sidebar(state, rect, sidebar)

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

  @spec render_git_status_sidebar(state(), Layout.rect() | nil) :: [DisplayList.draw()]
  defp render_git_status_sidebar(state, rect) do
    module = :"Elixir.MingaGitPorcelain.Shell.Traditional.GitStatusRenderer"

    if git_porcelain_running?() and Code.ensure_loaded?(module) and
         function_exported?(module, :render, 2) do
      :erlang.apply(module, :render, [state, rect])
    else
      []
    end
  end

  @spec git_porcelain_running?() :: boolean()
  defp git_porcelain_running? do
    case Process.whereis(Minga.Extension.Registry) do
      nil -> false
      _pid -> git_porcelain_running_in_registry?()
    end
  catch
    :exit, _reason -> false
  end

  @spec git_porcelain_running_in_registry?() :: boolean()
  defp git_porcelain_running_in_registry? do
    case Minga.Extension.Registry.get(:minga_git_porcelain) do
      {:ok, %{status: :running}} -> true
      _ -> false
    end
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
    text |> Unicode.truncate_display_width(width) |> Unicode.pad_display_trailing(width)
  end
end
