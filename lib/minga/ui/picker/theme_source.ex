defmodule Minga.UI.Picker.ThemeSource do
  @moduledoc """
  Picker source for browsing and live-previewing editor themes.

  Lists all built-in themes with a dark/light label. Live preview is
  enabled: navigating the picker temporarily switches the entire UI
  to the highlighted theme. Cancelling restores the original.
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.UI.Picker.Item

  alias Minga.UI.Theme

  @impl true
  @spec title() :: String.t()
  def title, do: "Theme"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
    Theme.available()
    |> Enum.sort()
    |> Enum.map(fn name ->
      %Item{id: name, label: "󰏘 #{display_name(name)}", description: description(name)}
    end)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: name}, state) when is_atom(name) do
    %{state | theme: Theme.get!(name)}
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(%{picker_ui: %{restore_theme: %Theme{} = theme}} = state) do
    %{state | theme: theme}
  end

  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec display_name(atom()) :: String.t()
  defp display_name(name) do
    name
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @spec description(atom()) :: String.t()
  defp description(name) do
    case name do
      :catppuccin_frappe -> "Dark, Catppuccin family"
      :catppuccin_latte -> "Light, Catppuccin family"
      :catppuccin_macchiato -> "Dark, Catppuccin family"
      :catppuccin_mocha -> "Dark, Catppuccin family"
      :doom_one -> "Dark, Doom Emacs"
      :one_dark -> "Dark, Atom"
      :one_light -> "Light, Atom"
      _ -> ""
    end
  end
end
