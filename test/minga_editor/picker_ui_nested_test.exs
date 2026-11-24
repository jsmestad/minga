defmodule MingaEditor.PickerUINestedTest do
  @moduledoc "Tests child pickers that a source opens in place of its own picker."

  use ExUnit.Case, async: true

  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item

  @escape 27
  @enter 13

  defmodule ParentSource do
    @moduledoc false
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "Parent"

    @impl true
    def candidates(_context) do
      [
        %Item{id: :alpha, label: "alpha model"},
        %Item{id: :beta, label: "beta model"},
        %Item{id: :more, label: "More options"}
      ]
    end

    @impl true
    def selection_disposition(%Item{id: :more}, _context),
      do: {:stay_open, {:nested, MingaEditor.PickerUINestedTest.ChildSource, %{from: :parent}}}

    def selection_disposition(%Item{}, _context), do: :accept

    @impl true
    def on_select(%Item{id: id}, state) do
      send(self(), {:parent_selected, id})
      state
    end
  end

  defmodule ChildSource do
    @moduledoc false
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "Child"

    @impl true
    def candidates(%{picker_ui: %{context: %{from: from}}}) do
      [
        %Item{id: {:child, from, 1}, label: "first action"},
        %Item{id: {:child, from, 2}, label: "second action"}
      ]
    end

    @impl true
    def on_select(%Item{id: id}, state) do
      send(self(), {:child_selected, id})
      state
    end
  end

  # The parent filtered to "o" with "More options" selected, ready to open its child.
  defp parent_on_more do
    TestHelpers.base_state(content: "initial", rendering: :disabled)
    |> PickerUI.open(ParentSource)
    |> PickerUI.update_picker(fn ps ->
      picker = Picker.filter(ps.picker, "o")
      PickerState.update_picker(ps, Picker.select_id(picker, :more))
    end)
  end

  defp picker_ui(state) do
    {:picker, %{picker_ui: picker_ui}} = state.shell_runtime.state.modal
    picker_ui
  end

  defp activation_id(state, item_id) do
    offer = picker_ui(state).activation_offer
    {id, _index, _item} = Enum.find(offer.items, fn {_id, _index, item} -> item.id == item_id end)
    id
  end

  test "Escape in a child picker returns to the parent with its query and selection" do
    parent = parent_on_more()
    parent_generation = picker_ui(parent).query_generation

    child = PickerUI.handle_key(parent, @enter, 0)
    child_ui = picker_ui(child)

    assert child_ui.source == ChildSource
    assert child_ui.picker.query == ""
    assert Enum.map(child_ui.picker.filtered, & &1.label) == ["first action", "second action"]
    # A fresh query session makes frontends replace the parent's query with the child's.
    refute child_ui.query_generation == parent_generation
    refute_received {:parent_selected, _id}

    returned = PickerUI.handle_key(child, @escape, 0)
    returned_ui = picker_ui(returned)

    assert returned_ui.source == ParentSource
    assert returned_ui.picker.query == "o"
    assert Picker.selected_id(returned_ui.picker) == :more
    refute returned_ui.query_generation in [parent_generation, child_ui.query_generation]
    assert returned_ui.parent == nil

    assert PickerUI.handle_key(returned, @escape, 0).shell_runtime.state.modal == :none
  end

  test "selecting a child item closes both pickers and runs the child's selection" do
    child = PickerUI.handle_key(parent_on_more(), @enter, 0)
    closed = PickerUI.handle_key(child, @enter, 0)

    assert closed.shell_runtime.state.modal == :none
    assert_received {:child_selected, {:child, :parent, 1}}
    refute_received {:parent_selected, _id}
  end

  test "a click opens the child, and a stale click on a parent row does nothing" do
    parent = parent_on_more()
    parent_generation = picker_ui(parent).activation_offer.generation
    alpha = activation_id(parent, :alpha)

    child =
      GuiActionHandler.dispatch(
        parent,
        {:picker_item_activate, parent_generation, activation_id(parent, :more)}
      )

    assert picker_ui(child).source == ChildSource

    stale = GuiActionHandler.dispatch(child, {:picker_item_activate, parent_generation, alpha})
    assert picker_ui(stale).source == ChildSource
    refute_received {:parent_selected, _id}

    child_generation = picker_ui(child).activation_offer.generation
    second = activation_id(child, {:child, :parent, 2})
    closed = GuiActionHandler.dispatch(child, {:picker_item_activate, child_generation, second})

    assert closed.shell_runtime.state.modal == :none
    assert_received {:child_selected, {:child, :parent, 2}}
  end
end
