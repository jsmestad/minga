defmodule Minga.Buffer.DirtyFlagPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :tmp_dir

  property "dirty state follows the saved revision across random edits, undo, redo, and save", %{
    tmp_dir: dir
  } do
    check all(
            operations <- StreamData.list_of(operation_generator(), min_length: 1, max_length: 40)
          ) do
      case_id = System.unique_integer([:positive])
      child_id = {BufferProcess, case_id}
      path = Path.join(dir, "dirty-property-#{case_id}.txt")
      File.write!(path, "start")

      buffer = start_supervised!({BufferProcess, file_path: path}, id: child_id)

      try do
        initial = %{id: 0, content: "start", cursor: 0}
        model = %{current: initial, saved_id: 0, undo: [], redo: [], next_id: 1}

        Enum.reduce(operations, model, fn operation, model ->
          model = apply_operation(buffer, operation, model)

          assert BufferProcess.content(buffer) == model.current.content
          assert BufferProcess.dirty?(buffer) == (model.current.id != model.saved_id)

          model
        end)
      after
        :ok = stop_supervised(child_id)
      end
    end
  end

  defp operation_generator do
    StreamData.frequency([
      {5, StreamData.map(StreamData.member_of(~w(a b c x y z)), &{:insert, &1})},
      {2, StreamData.constant(:undo)},
      {2, StreamData.constant(:redo)},
      {2, StreamData.constant(:save)},
      {1, StreamData.constant(:break)}
    ])
  end

  defp apply_operation(buffer, {:insert, char}, model) do
    :ok = BufferProcess.break_undo_coalescing(buffer)
    :ok = BufferProcess.insert_char(buffer, char)

    current = model.current
    {left, right} = String.split_at(current.content, current.cursor)

    revision = %{
      id: model.next_id,
      content: left <> char <> right,
      cursor: current.cursor + byte_size(char)
    }

    %{
      model
      | current: revision,
        undo: [current | model.undo],
        redo: [],
        next_id: model.next_id + 1
    }
  end

  defp apply_operation(buffer, :undo, %{undo: [previous | rest]} = model) do
    :ok = BufferProcess.undo(buffer)
    %{model | current: previous, undo: rest, redo: [model.current | model.redo]}
  end

  defp apply_operation(buffer, :undo, model) do
    :ok = BufferProcess.undo(buffer)
    model
  end

  defp apply_operation(buffer, :redo, %{redo: [next | rest]} = model) do
    :ok = BufferProcess.redo(buffer)
    %{model | current: next, redo: rest, undo: [model.current | model.undo]}
  end

  defp apply_operation(buffer, :redo, model) do
    :ok = BufferProcess.redo(buffer)
    model
  end

  defp apply_operation(buffer, :save, model) do
    :ok = BufferProcess.save(buffer)
    %{model | saved_id: model.current.id}
  end

  defp apply_operation(buffer, :break, model) do
    :ok = BufferProcess.break_undo_coalescing(buffer)
    model
  end
end
