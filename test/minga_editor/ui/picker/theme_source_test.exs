defmodule MingaEditor.UI.Picker.ThemeSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ThemeSource
  alias MingaEditor.UI.Theme
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

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
    test "returns all bundled themes including fallback" do
      items = ThemeSource.candidates(%{})
      assert Enum.count(items) >= 8
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
      state = base_state() |> EditorState.apply_theme(Theme.get!(:doom_one))

      new_state =
        ThemeSource.on_select(
          %Item{id: :one_dark, label: "One Dark", description: "Dark, Atom"},
          state
        )

      assert new_state.appearance.theme.name == :one_dark
    end

    test "does not write renderer state into editor windows" do
      state = base_state()

      before =
        Map.new(state.workspace.windows.map, fn {id, window} -> {id, window.render_cache} end)

      new_state =
        ThemeSource.on_select(
          %Item{id: :one_dark, label: "One Dark", description: "Dark, Atom"},
          state
        )

      assert Map.new(new_state.workspace.windows.map, fn {id, window} ->
               {id, window.render_cache}
             end) == before
    end
  end

  describe "on_cancel/1" do
    test "restores the original theme from picker state" do
      original = Theme.get!(:doom_one)

      state =
        base_state()
        |> EditorState.apply_theme(Theme.get!(:one_dark))
        |> ModalWorkflow.open({:picker, PickerPayload.new(%PickerState{restore_theme: original})})

      restored = ThemeSource.on_cancel(state)
      assert restored.appearance.theme.name == :doom_one
    end

    test "cancel restore marks editor window retained state reset-pending" do
      original = Theme.get!(:doom_one)

      state = base_state() |> EditorState.apply_theme(Theme.get!(:one_dark))

      state =
        ModalWorkflow.open(
          state,
          {:picker, PickerPayload.new(%PickerState{restore_theme: original})}
        )

      restored = ThemeSource.on_cancel(state)

      assert restored.appearance.theme.name == :doom_one

      assert Enum.all?(Map.values(restored.workspace.windows.map), fn %Window{} = window ->
               match?(%MingaEditor.Window.RenderCache{}, window.render_cache)
             end)
    end

    test "returns state unchanged when no restore_theme" do
      state = base_state() |> EditorState.apply_theme(Theme.get!(:one_dark))

      assert ThemeSource.on_cancel(state) == state
    end
  end
end
