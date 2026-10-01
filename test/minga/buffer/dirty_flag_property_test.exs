defmodule Minga.Buffer.DirtyFlagPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.SaveState

  property "dirty state follows the saved revision across random edits, undo, redo, and save" do
    check all(
            operations <- StreamData.list_of(operation_generator(), min_length: 1, max_length: 40)
          ) do
      model = %{current: 0, saved: 0, undo: [], redo: [], next_id: 1}

      Enum.reduce(operations, {SaveState.new(), model}, fn operation, {state, model} ->
        {state, model} = apply_operation(state, operation, model)
        assert SaveState.version(state) == model.current
        assert SaveState.saved_version(state) == model.saved
        assert SaveState.dirty?(state) == (model.current != model.saved)
        {state, model}
      end)
    end
  end

  defp operation_generator do
    StreamData.frequency([
      {5, StreamData.constant(:edit)},
      {2, StreamData.constant(:undo)},
      {2, StreamData.constant(:redo)},
      {2, StreamData.constant(:save)}
    ])
  end

  defp apply_operation(state, :edit, model) do
    next = %{
      model
      | current: model.next_id,
        undo: [model.current | model.undo],
        redo: [],
        next_id: model.next_id + 1
    }

    {SaveState.mark_changed(state), next}
  end

  defp apply_operation(state, :undo, %{undo: [previous | rest]} = model) do
    {SaveState.restore_version(state, previous),
     %{model | current: previous, undo: rest, redo: [model.current | model.redo]}}
  end

  defp apply_operation(state, :redo, %{redo: [next | rest]} = model) do
    {SaveState.restore_version(state, next),
     %{model | current: next, redo: rest, undo: [model.current | model.undo]}}
  end

  defp apply_operation(state, :save, model) do
    {SaveState.mark_saved(state, {0, 0}, ""), %{model | saved: model.current}}
  end

  defp apply_operation(state, _empty_history, model), do: {state, model}
end
