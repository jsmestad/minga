defmodule Minga.Input.PickerMouseTest do
  @moduledoc "Tests for mouse interaction with the picker overlay."
  use ExUnit.Case, async: true

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Input.Picker, as: PickerInput
  alias Minga.Picker, as: PickerData

  defmodule TestSource do
    @moduledoc false
    @behaviour Minga.Picker.Source

    @impl true
    def on_select(item, state), do: Map.put(state, :selected_item, item)
    @impl true
    def on_cancel(state), do: state
    @impl true
    def candidates(_query), do: []
    @impl true
    def title, do: "Test"
  end

  defp picker_state(items) do
    picker =
      PickerData.new(items, max_visible: 10, title: "Test")

    %EditorState{
      port_manager: nil,
      workspace: %Minga.Workspace.State{
        viewport: %Viewport{rows: 30, cols: 80, top: 0, left: 0},
        vim: VimState.new()
      },
      picker_ui: %Minga.Editor.State.Picker{picker: picker, source: TestSource}
    }
  end

  describe "scroll wheel" do
    test "wheel_down moves picker selection down" do
      state = picker_state([%{id: 1, label: "one"}, %{id: 2, label: "two"}])
      {:handled, new_state} = PickerInput.handle_mouse(state, 10, 10, :wheel_down, 0, :press, 1)
      assert new_state.picker_ui.picker.selected == 1
    end

    test "wheel_up moves picker selection up" do
      state = picker_state([%{id: 1, label: "one"}, %{id: 2, label: "two"}])
      # Move down first, then up
      {:handled, state} = PickerInput.handle_mouse(state, 10, 10, :wheel_down, 0, :press, 1)
      {:handled, new_state} = PickerInput.handle_mouse(state, 10, 10, :wheel_up, 0, :press, 1)
      assert new_state.picker_ui.picker.selected == 0
    end
  end

  describe "click to select" do
    test "clicking a candidate selects and confirms it" do
      items = [%{id: 1, label: "alpha"}, %{id: 2, label: "beta"}, %{id: 3, label: "gamma"}]
      state = picker_state(items)

      # Items render upward from prompt_row (29). With 3 items:
      # separator at row 25, items at rows 26, 27, 28, prompt at 29
      {:handled, new_state} = PickerInput.handle_mouse(state, 26, 10, :left, 0, :press, 1)

      # Picker should be closed
      assert new_state.picker_ui.picker == nil
      # Source's on_select should have been called
      assert Map.has_key?(new_state, :selected_item)
    end

    test "clicking outside items area is handled but does nothing" do
      items = [%{id: 1, label: "one"}]
      state = picker_state(items)

      # Click on row 0 (well above the picker)
      {:handled, new_state} = PickerInput.handle_mouse(state, 0, 10, :left, 0, :press, 1)
      # Picker should still be open
      assert new_state.picker_ui.picker != nil
    end
  end

  describe "centered picker clicks" do
    defp centered_picker_state(items) do
      picker =
        PickerData.new(items, max_visible: 10, title: "Test")

      %EditorState{
        port_manager: nil,
        workspace: %Minga.Workspace.State{
          viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
          vim: VimState.new()
        },
        picker_ui: %Minga.Editor.State.Picker{
          picker: picker,
          source: TestSource,
          layout: :centered
        }
      }
    end

    test "clicking an item inside the centered float selects it" do
      items = [%{id: 1, label: "alpha"}, %{id: 2, label: "beta"}]
      state = centered_picker_state(items)

      # 70% of 24 rows = 16 rows, centered: box starts at row 4
      # Interior starts at row 5 (box_row + 1 border)
      # First item is at interior row 0 = screen row 5
      {:handled, new_state} = PickerInput.handle_mouse(state, 5, 20, :left, 0, :press, 1)

      assert new_state.picker_ui.picker == nil
      assert Map.has_key?(new_state, :selected_item)
    end

    test "clicking outside the centered float dismisses the picker" do
      items = [%{id: 1, label: "alpha"}]
      state = centered_picker_state(items)

      # Click at row 0, col 0 (outside the centered box)
      {:handled, new_state} = PickerInput.handle_mouse(state, 0, 0, :left, 0, :press, 1)

      # Picker should be closed (dismissed), no item selected
      assert new_state.picker_ui.picker == nil
      refute Map.has_key?(new_state, :selected_item)
    end

    test "scroll wheel works inside centered picker" do
      items = [%{id: 1, label: "one"}, %{id: 2, label: "two"}]
      state = centered_picker_state(items)

      {:handled, new_state} =
        PickerInput.handle_mouse(state, 10, 20, :wheel_down, 0, :press, 1)

      assert new_state.picker_ui.picker.selected == 1
    end
  end

  describe "passthrough when inactive" do
    test "passes through when no picker is active" do
      state = %EditorState{
        port_manager: nil,
        workspace: %Minga.Workspace.State{
          viewport: %Viewport{rows: 30, cols: 80, top: 0, left: 0},
          vim: VimState.new()
        }
      }

      {:passthrough, ^state} = PickerInput.handle_mouse(state, 10, 10, :left, 0, :press, 1)
    end
  end
end
