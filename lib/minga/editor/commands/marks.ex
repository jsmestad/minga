defmodule Minga.Editor.Commands.Marks do
  @moduledoc """
  Mark commands: set a mark, jump to a mark (line or exact), and jump to the
  last cursor position.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  def execute(%{buffers: %{active: buf}, marks: marks} = state, {:set_mark, char})
      when is_binary(char) and is_pid(buf) do
    pos = BufferServer.cursor(buf)
    buf_marks = Map.get(marks, buf, %{})
    new_marks = Map.put(marks, buf, Map.put(buf_marks, char, pos))
    %{state | marks: new_marks}
  end

  def execute(%{buffers: %{active: buf}, marks: marks} = state, {:jump_to_mark_line, char})
      when is_binary(char) and is_pid(buf) do
    buf_marks = Map.get(marks, buf, %{})

    case Map.get(buf_marks, char) do
      nil ->
        state

      {mark_line, _mark_col} ->
        current_pos = BufferServer.cursor(buf)
        {content, _} = BufferServer.content_and_cursor(buf)
        tmp_buf = Document.new(content)
        target = Minga.Motion.first_non_blank(tmp_buf, {mark_line, 0})
        BufferServer.move_to(buf, target)
        Helpers.save_jump_pos(state, current_pos, target)
    end
  end

  def execute(%{buffers: %{active: buf}, marks: marks} = state, {:jump_to_mark_exact, char})
      when is_binary(char) and is_pid(buf) do
    buf_marks = Map.get(marks, buf, %{})

    case Map.get(buf_marks, char) do
      nil ->
        state

      mark_pos ->
        current_pos = BufferServer.cursor(buf)
        BufferServer.move_to(buf, mark_pos)
        Helpers.save_jump_pos(state, current_pos, mark_pos)
    end
  end

  def execute(%{buffers: %{active: buf}, last_jump_pos: last_pos} = state, :jump_to_last_pos_line)
      when is_pid(buf) and not is_nil(last_pos) do
    current_pos = BufferServer.cursor(buf)
    {last_line, _} = last_pos
    {content, _} = BufferServer.content_and_cursor(buf)
    tmp_buf = Document.new(content)
    target = Minga.Motion.first_non_blank(tmp_buf, {last_line, 0})
    BufferServer.move_to(buf, target)
    %{state | last_jump_pos: current_pos}
  end

  def execute(state, :jump_to_last_pos_line), do: state

  def execute(
        %{buffers: %{active: buf}, last_jump_pos: last_pos} = state,
        :jump_to_last_pos_exact
      )
      when is_pid(buf) and not is_nil(last_pos) do
    current_pos = BufferServer.cursor(buf)
    BufferServer.move_to(buf, last_pos)
    %{state | last_jump_pos: current_pos}
  end

  def execute(state, :jump_to_last_pos_exact), do: state
end
