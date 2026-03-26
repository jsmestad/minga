defmodule Minga.Editor.Commands.Marks do
  @moduledoc """
  Mark commands: set a mark, jump to a mark (line or exact), and jump to the
  last cursor position.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @command_specs [
    {:jump_to_last_pos_line, "Jump to last position (line)", true},
    {:jump_to_last_pos_exact, "Jump to last position (exact)", true}
  ]

  @spec execute(state(), Mode.command()) :: state()

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{marks: marks}}} = state,
        {:set_mark, char}
      )
      when is_binary(char) and is_pid(buf) do
    pos = Buffer.cursor(buf)
    buf_marks = Map.get(marks, buf, %{})
    new_marks = Map.put(marks, buf, Map.put(buf_marks, char, pos))

    %{
      state
      | workspace: %{state.workspace | editing: %{state.workspace.editing | marks: new_marks}}
    }
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{marks: marks}}} = state,
        {:jump_to_mark_line, char}
      )
      when is_binary(char) and is_pid(buf) do
    buf_marks = Map.get(marks, buf, %{})

    case Map.get(buf_marks, char) do
      nil ->
        state

      {mark_line, _mark_col} ->
        current_pos = Buffer.cursor(buf)
        {content, _} = Buffer.content_and_cursor(buf)
        tmp_buf = Buffer.new_document(content)
        target = Minga.Editing.first_non_blank(tmp_buf, {mark_line, 0})
        Buffer.move_to(buf, target)
        Helpers.save_jump_pos(state, current_pos, target)
    end
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{marks: marks}}} = state,
        {:jump_to_mark_exact, char}
      )
      when is_binary(char) and is_pid(buf) do
    buf_marks = Map.get(marks, buf, %{})

    case Map.get(buf_marks, char) do
      nil ->
        state

      mark_pos ->
        current_pos = Buffer.cursor(buf)
        Buffer.move_to(buf, mark_pos)
        Helpers.save_jump_pos(state, current_pos, mark_pos)
    end
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{last_jump_pos: last_pos}}} = state,
        :jump_to_last_pos_line
      )
      when is_pid(buf) and not is_nil(last_pos) do
    current_pos = Buffer.cursor(buf)
    {last_line, _} = last_pos
    {content, _} = Buffer.content_and_cursor(buf)
    tmp_buf = Buffer.new_document(content)
    target = Minga.Editing.first_non_blank(tmp_buf, {last_line, 0})
    Buffer.move_to(buf, target)

    %{
      state
      | workspace: %{
          state.workspace
          | editing: %{state.workspace.editing | last_jump_pos: current_pos}
        }
    }
  end

  def execute(state, :jump_to_last_pos_line), do: state

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{last_jump_pos: last_pos}}} = state,
        :jump_to_last_pos_exact
      )
      when is_pid(buf) and not is_nil(last_pos) do
    current_pos = Buffer.cursor(buf)
    Buffer.move_to(buf, last_pos)

    %{
      state
      | workspace: %{
          state.workspace
          | editing: %{state.workspace.editing | last_jump_pos: current_pos}
        }
    }
  end

  def execute(state, :jump_to_last_pos_exact), do: state

  @impl Minga.Command.Provider
  def __commands__ do
    Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
      %Minga.Command{
        name: name,
        description: desc,
        requires_buffer: requires_buffer,
        execute: fn state -> execute(state, name) end
      }
    end)
  end
end
