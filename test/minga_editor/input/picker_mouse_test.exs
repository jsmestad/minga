defmodule MingaEditor.Input.PickerMouseTest do
  @moduledoc "Tests for mouse interaction with the picker overlay."
  use ExUnit.Case, async: true

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Input.Picker, as: PickerInput
  alias MingaEditor.UI.Picker, as: PickerData

  defmodule TestSource do
    @moduledoc false
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def on_select(item, state), do: Map.put(state, :selected_item, item)
    @impl true
    def on_cancel(state), do: state
    @impl true
    def candidates(_query), do: []
    @impl true
    def title, do: "Test"
  end

  defp picker_state(items, max_visible \\ 10) do
    picker =
      PickerData.new(items, max_visible: max_visible, title: "Test")

    vp = Viewport.new(30, 80)

    %EditorState{
      port_manager: nil,
      terminal_viewport: vp,
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        viewport: vp
      },
      shell_state: %MingaEditor.Shell.Traditional.State{
        modal:
          {:picker,
           PickerPayload.new(%MingaEditor.State.Picker{picker: picker, source: TestSource})}
      }
    }
  end

  describe "scroll wheel" do
    test "wheel_down moves picker selection down" do
      state = picker_state([%{id: 1, label: "one"}, %{id: 2, label: "two"}])
      {:handled, new_state} = PickerInput.handle_mouse(state, 10, 10, :wheel_down, 0, :press, 1)
      {:picker, %{picker_ui: %{picker: pui}}} = new_state.shell_state.modal
      assert pui.selected == 1
    end

    test "wheel_up moves picker selection up" do
      state = picker_state([%{id: 1, label: "one"}, %{id: 2, label: "two"}])
      # Move down first, then up
      {:handled, state} = PickerInput.handle_mouse(state, 10, 10, :wheel_down, 0, :press, 1)
      {:handled, new_state} = PickerInput.handle_mouse(state, 10, 10, :wheel_up, 0, :press, 1)
      {:picker, %{picker_ui: %{picker: pui}}} = new_state.shell_state.modal
      assert pui.selected == 0
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
      assert new_state.shell_state.modal == :none
      # Source's on_select should have been called
      assert new_state.selected_item.id == 1
    end

    test "clicking the only bottom candidate selects and confirms it" do
      state = picker_state([%{id: 1, label: "only"}])

      {:handled, new_state} = PickerInput.handle_mouse(state, 28, 10, :left, 0, :press, 1)

      assert new_state.shell_state.modal == :none
      assert new_state.selected_item.id == 1
    end

    test "clicking the last rendered bottom candidate selects it when the list is viewport-capped" do
      items = for n <- 1..40, do: %{id: n, label: "item-#{n}"}
      state = picker_state(items, 40)

      # 30 rows leave 27 item rows, plus separator and prompt. The last rendered item is item 27.
      {:handled, new_state} = PickerInput.handle_mouse(state, 28, 10, :left, 0, :press, 1)

      assert new_state.shell_state.modal == :none
      assert new_state.selected_item.id == 27
    end

    test "clicking the bottom picker separator does not select from the end of the list" do
      items = for n <- 1..40, do: %{id: n, label: "item-#{n}"}
      state = picker_state(items, 40)

      {:handled, new_state} = PickerInput.handle_mouse(state, 1, 10, :left, 0, :press, 1)

      assert ModalOverlay.match(new_state.shell_state.modal, :picker)
      refute Map.has_key?(new_state, :selected_item)
    end

    test "clicking outside items area is handled but does nothing" do
      items = [%{id: 1, label: "one"}]
      state = picker_state(items)

      # Click on row 0 (well above the picker)
      {:handled, new_state} = PickerInput.handle_mouse(state, 0, 10, :left, 0, :press, 1)
      # Picker should still be open
      assert ModalOverlay.match(new_state.shell_state.modal, :picker)
    end
  end

  describe "centered picker clicks" do
    defp centered_picker_state(items, max_visible \\ 10) do
      picker =
        PickerData.new(items, max_visible: max_visible, title: "Test")

      %EditorState{
        port_manager: nil,
        workspace: %MingaEditor.Session.State{
          editing: VimState.new(),
          viewport: Viewport.new(24, 80)
        },
        shell_state: %MingaEditor.Shell.Traditional.State{
          modal:
            {:picker,
             PickerPayload.new(%MingaEditor.State.Picker{
               picker: picker,
               source: TestSource,
               layout: :centered
             })}
        }
      }
    end

    test "clicking an item inside the centered float selects it" do
      items = [%{id: 1, label: "alpha"}, %{id: 2, label: "beta"}]
      state = centered_picker_state(items)

      # Two visible items + prompt + border = 5 rows, centered: box starts at row 9.
      # Interior starts at row 10 (box_row + 1 border).
      # First item is at interior row 0 = screen row 10.
      {:handled, new_state} = PickerInput.handle_mouse(state, 10, 20, :left, 0, :press, 1)

      assert new_state.shell_state.modal == :none
      assert Map.has_key?(new_state, :selected_item)
    end

    test "clicking the prompt row in a tall centered picker ignores hidden items" do
      items = for n <- 1..20, do: %{id: n, label: "item-#{n}"}
      state = centered_picker_state(items, 20)

      max_height = max(div(24 * 7, 10), 5)
      box_h = min(length(items) + 3, max_height)
      box_row = div(24 - box_h, 2)
      prompt_row = box_row + box_h - 2

      # The prompt row is still inside the hit-test rect; it must not map to a hidden item.
      {:handled, new_state} = PickerInput.handle_mouse(state, prompt_row, 20, :left, 0, :press, 1)

      assert ModalOverlay.match(new_state.shell_state.modal, :picker)
      refute Map.has_key?(new_state, :selected_item)
    end

    test "clicking the last rendered row in a tall centered picker selects the selected-visible slice" do
      items = for n <- 1..20, do: %{id: n, label: "item-#{n}"}

      state =
        items
        |> centered_picker_state(20)
        |> MingaEditor.PickerUI.update_picker(fn picker_ui ->
          picker =
            Enum.reduce(1..19, picker_ui.picker, fn _n, acc -> PickerData.move_down(acc) end)

          %{picker_ui | picker: picker}
        end)

      max_height = max(div(24 * 7, 10), 5)
      box_h = min(length(items) + 3, max_height)
      box_row = div(24 - box_h, 2)
      last_item_row = box_row + 1 + (box_h - 3) - 1

      {:handled, new_state} =
        PickerInput.handle_mouse(state, last_item_row, 20, :left, 0, :press, 1)

      assert new_state.shell_state.modal == :none
      assert new_state.selected_item.id == 20
    end

    test "clicking outside the centered float dismisses the picker" do
      items = [%{id: 1, label: "alpha"}]
      state = centered_picker_state(items)

      # One visible item + prompt + border = 4 rows, centered: box starts at row 10.
      # Row 5 was inside the old 70% hit-test rect but is outside the compact popup.
      {:handled, new_state} = PickerInput.handle_mouse(state, 5, 20, :left, 0, :press, 1)

      # Picker should be closed (dismissed), no item selected
      assert new_state.shell_state.modal == :none
      refute Map.has_key?(new_state, :selected_item)
    end

    test "scroll wheel works inside centered picker" do
      items = [%{id: 1, label: "one"}, %{id: 2, label: "two"}]
      state = centered_picker_state(items)

      {:handled, new_state} =
        PickerInput.handle_mouse(state, 10, 20, :wheel_down, 0, :press, 1)

      {:picker, %{picker_ui: %{picker: pui}}} = new_state.shell_state.modal
      assert pui.selected == 1
    end
  end

  describe "passthrough when inactive" do
    test "passes through when no picker is active" do
      state = %EditorState{
        port_manager: nil,
        workspace: %MingaEditor.Session.State{
          editing: VimState.new(),
          viewport: Viewport.new(30, 80)
        }
      }

      {:passthrough, ^state} = PickerInput.handle_mouse(state, 10, 10, :left, 0, :press, 1)
    end
  end
end
