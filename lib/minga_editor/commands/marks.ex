defmodule MingaEditor.Commands.Marks do
  @moduledoc """
  Mark commands: set a mark, jump to a mark (line or exact), and jump to the
  last cursor position.

  Successful jumps mark the window's authoritative-scroll marker (#2652) in
  their success branch, so a jump landing on the same committed top still
  discards a frontend-held local scroll offset. A jump to an unset mark (or
  with no last position) is a no-op and deliberately does not mark.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias MingaEditor.Commands.Helpers
  alias MingaEditor.State, as: EditorState
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
      | workspace:
          MingaEditor.Session.State.set_editing(
            state.workspace,
            MingaEditor.VimState.set_marks(state.workspace.editing, new_marks)
          )
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
        tmp_buf = Document.new(content)
        target = Minga.Editing.first_non_blank(tmp_buf, {mark_line, 0})
        Buffer.move_to(buf, target)

        state
        |> then(fn state ->
          %{
            state
            | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
          }
        end)
        |> Helpers.save_jump_pos(current_pos, target)
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

        state
        |> then(fn state ->
          %{
            state
            | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
          }
        end)
        |> Helpers.save_jump_pos(current_pos, mark_pos)
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
    tmp_buf = Document.new(content)
    target = Minga.Editing.first_non_blank(tmp_buf, {last_line, 0})
    Buffer.move_to(buf, target)

    state
    |> then(fn state ->
      %{state | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)}
    end)
    |> then(fn state ->
      %{
        state
        | workspace:
            MingaEditor.Session.State.set_editing(
              state.workspace,
              MingaEditor.VimState.set_last_jump_pos(state.workspace.editing, current_pos)
            )
      }
    end)
  end

  def execute(state, :jump_to_last_pos_line), do: state

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{last_jump_pos: last_pos}}} = state,
        :jump_to_last_pos_exact
      )
      when is_pid(buf) and not is_nil(last_pos) do
    current_pos = Buffer.cursor(buf)
    Buffer.move_to(buf, last_pos)

    state
    |> then(fn state ->
      %{state | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)}
    end)
    |> then(fn state ->
      %{
        state
        | workspace:
            MingaEditor.Session.State.set_editing(
              state.workspace,
              MingaEditor.VimState.set_last_jump_pos(state.workspace.editing, current_pos)
            )
      }
    end)
  end

  def execute(state, :jump_to_last_pos_exact), do: state

  commands(@command_specs)
end
