defmodule Minga.Test.DeleteActionPickerSource do
  @moduledoc "Test picker source with a delete action for PickerUI action dispatch regressions."

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Delete Action Test"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_ctx), do: [%Item{id: :delete_me, label: "Delete me"}]

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{}, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @impl true
  @spec actions(Item.t()) :: [MingaEditor.UI.Picker.Source.action_entry()]
  def actions(%Item{id: :delete_me}), do: [{"Delete", :delete}]
  def actions(_item), do: []

  @impl true
  @spec on_action(atom(), Item.t(), term()) :: term()
  def on_action(:delete, %Item{id: :delete_me}, state) do
    EditorState.set_status(state, "Deleted via action")
  end

  def on_action(_action, _item, state), do: state
end
