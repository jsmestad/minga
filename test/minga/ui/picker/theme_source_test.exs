defmodule Minga.UI.Picker.ThemeSourceTest do
  use ExUnit.Case, async: true

  alias Minga.UI.Picker.Item
  alias Minga.UI.Picker.ThemeSource
  alias Minga.UI.Theme

  describe "title/0" do
    test "returns Theme" do
      assert ThemeSource.title() == "Theme"
    end
  end

  describe "preview?/0" do
    test "returns true for live preview" do
      assert ThemeSource.preview?() == true
    end
  end

  describe "candidates/1" do
    test "returns all 7 built-in themes" do
      items = ThemeSource.candidates(%{})
      assert length(items) == 7
    end

    test "items are sorted alphabetically by name" do
      items = ThemeSource.candidates(%{})
      names = Enum.map(items, fn %Item{id: name} -> name end)
      assert names == Enum.sort(names)
    end

    test "each item has a human-readable label" do
      items = ThemeSource.candidates(%{})
      %Item{label: label} = Enum.find(items, fn %Item{id: n} -> n == :doom_one end)
      assert label == "󰏘 Doom One"
    end

    test "each item has a description with dark/light classification" do
      items = ThemeSource.candidates(%{})
      %Item{description: desc} = Enum.find(items, fn %Item{id: n} -> n == :catppuccin_latte end)
      assert desc =~ "Light"
    end
  end

  describe "on_select/2" do
    test "changes state.theme to the selected theme" do
      state = %{theme: Theme.get!(:doom_one)}

      new_state =
        ThemeSource.on_select(
          %Item{id: :one_dark, label: "One Dark", description: "Dark, Atom"},
          state
        )

      assert new_state.theme.name == :one_dark
    end
  end

  describe "on_cancel/1" do
    test "restores the original theme from picker state" do
      original = Theme.get!(:doom_one)

      state = %{
        theme: Theme.get!(:one_dark),
        shell_state: %Minga.Shell.Traditional.State{picker_ui: %{restore_theme: original}}
      }

      restored = ThemeSource.on_cancel(state)
      assert restored.theme.name == :doom_one
    end

    test "returns state unchanged when no restore_theme" do
      state = %{
        theme: Theme.get!(:one_dark),
        shell_state: %Minga.Shell.Traditional.State{picker_ui: %{restore_theme: nil}}
      }

      assert ThemeSource.on_cancel(state) == state
    end
  end
end
