defmodule Minga.UI.Picker.AgentGroupIconSource do
  @moduledoc """
  Picker source for selecting a workspace icon from curated SF Symbols.

  Shows icons organized by category with the symbol name as description.
  Selecting an icon sets it on the active workspace.
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.Editor.State.AgentGroup
  alias Minga.Editor.State.TabBar
  alias Minga.UI.Picker.Item

  @icons [
    # General
    {"folder", "General"},
    {"doc", "General"},
    {"doc.on.doc", "General"},
    {"tray.full", "General"},
    {"archivebox", "General"},
    {"bookmark", "General"},
    {"tag", "General"},
    {"flag", "General"},
    {"pin", "General"},
    {"star", "General"},
    # Code
    {"chevron.left.forwardslash.chevron.right", "Code"},
    {"terminal", "Code"},
    {"cpu", "Code"},
    {"memorychip", "Code"},
    {"server.rack", "Code"},
    {"network", "Code"},
    {"curlybraces", "Code"},
    {"function", "Code"},
    {"number", "Code"},
    # Tools
    {"hammer", "Tools"},
    {"wrench", "Tools"},
    {"screwdriver", "Tools"},
    {"gearshape", "Tools"},
    {"paintbrush", "Tools"},
    {"pencil", "Tools"},
    {"scissors", "Tools"},
    {"wand.and.stars", "Tools"},
    {"ant", "Tools"},
    {"ladybug", "Tools"},
    # Search & Analyze
    {"magnifyingglass", "Search"},
    {"doc.text.magnifyingglass", "Search"},
    {"chart.bar", "Search"},
    {"scope", "Search"},
    {"binoculars", "Search"},
    {"eye", "Search"},
    {"lightbulb", "Search"},
    # Communication
    {"bubble.left", "Communication"},
    {"bubble.left.and.bubble.right", "Communication"},
    {"envelope", "Communication"},
    {"paperplane", "Communication"},
    {"megaphone", "Communication"},
    {"bell", "Communication"},
    {"bolt", "Communication"},
    {"brain", "Communication"}
  ]

  @impl true
  @spec title() :: String.t()
  def title, do: "Set Workspace Icon"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(%{tab_bar: %TabBar{} = tb}) do
    current_icon =
      case TabBar.active_group(tb) do
        %AgentGroup{icon: icon} -> icon
        _ -> ""
      end

    Enum.map(@icons, fn {name, category} ->
      active_marker = if name == current_icon, do: " \u{2022}", else: ""

      %Item{
        id: name,
        label: "#{name}#{active_marker}",
        description: category
      }
    end)
  end

  def candidates(_), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: icon_name}, %{tab_bar: %TabBar{} = tb} = state) do
    ws_id = TabBar.active_group_id(tb)
    tb = TabBar.update_group(tb, ws_id, &AgentGroup.set_icon(&1, icon_name))
    %{state | tab_bar: tb}
  end

  def on_select(_, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state
end
