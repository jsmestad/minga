defmodule Minga.UI.Picker.TabSource do
  @moduledoc """
  Picker source that lists all open tabs (file and agent).

  File tabs show a filetype devicon and filename. Agent tabs show the
  robot icon and session title. The active tab is marked with a bullet.
  Selecting a tab switches to it.
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.Language
  alias Minga.UI.Picker.Context
  alias Minga.UI.Picker.Item

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.TabBar
  alias Minga.UI.Devicon

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch Tab"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{tab_bar: %TabBar{} = tb}) do
    Enum.map(tb.tabs, fn tab ->
      icon = tab_icon(tab)
      label = tab_display_label(tab)
      active_marker = if tab.id == tb.active_id, do: " \u{2022}", else: ""
      desc = tab_description(tab)

      %Item{id: tab.id, label: "#{icon} #{label}#{active_marker}", description: desc}
    end)
  end

  def candidates(_), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: tab_id}, state) do
    EditorState.switch_tab(state, tab_id)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec tab_icon(Minga.Editor.State.Tab.t()) :: String.t()
  defp tab_icon(%{kind: :agent}), do: Devicon.icon(:agent)

  defp tab_icon(%{kind: :file, label: label}) do
    Devicon.icon(Language.detect_filetype(label))
  end

  @spec tab_display_label(Minga.Editor.State.Tab.t()) :: String.t()
  defp tab_display_label(%{label: ""}), do: "[No Name]"
  defp tab_display_label(%{label: label}), do: label

  @spec tab_description(Minga.Editor.State.Tab.t()) :: String.t()
  defp tab_description(%{kind: :agent}), do: "agent"
  defp tab_description(%{kind: :file, label: label}), do: label
end
