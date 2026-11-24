defmodule MingaEditor.Commands.Marks do
  @moduledoc """
  Mark commands: set a mark, jump to a mark (line or exact), jump to the
  last cursor position, and walk the jump list (`⌃O`, `⌃I`, `SPC s j`).

  Successful jumps mark the window's authoritative-scroll marker (#2652) in
  their success branch, so a jump landing on the same committed top still
  discards a frontend-held local scroll offset. A jump to an unset mark (or
  with no last position) is a no-op and deliberately does not mark.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias MingaEditor.BufferActivation
  alias MingaEditor.Commands.Helpers
  alias MingaEditor.Editing
  alias MingaEditor.JumpList
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @command_specs [
    {:jump_to_last_pos_line, "Jump to last position (line)", true},
    {:jump_to_last_pos_exact, "Jump to last position (exact)", true},
    {:jump_back, "Jump back in the jump list", true},
    {:jump_forward, "Jump forward in the jump list", true}
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

        state = %{
          state
          | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
        }

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

        state = %{
          state
          | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
        }

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
    tmp_buf = Document.new(content)
    target = Minga.Editing.first_non_blank(tmp_buf, {last_line, 0})
    Buffer.move_to(buf, target)

    workspace = MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
    editing = MingaEditor.VimState.set_last_jump_pos(workspace.editing, current_pos)
    %{state | workspace: MingaEditor.Session.State.set_editing(workspace, editing)}
  end

  def execute(state, :jump_to_last_pos_line), do: state

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{last_jump_pos: last_pos}}} = state,
        :jump_to_last_pos_exact
      )
      when is_pid(buf) and not is_nil(last_pos) do
    current_pos = Buffer.cursor(buf)
    Buffer.move_to(buf, last_pos)

    workspace = MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
    editing = MingaEditor.VimState.set_last_jump_pos(workspace.editing, current_pos)
    %{state | workspace: MingaEditor.Session.State.set_editing(workspace, editing)}
  end

  def execute(state, :jump_to_last_pos_exact), do: state

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :jump_back) when is_pid(buf) do
    position = Buffer.cursor(buf)
    walk(state, JumpList.back(state.workspace.editing.jump_list, buf, position), :back)
  end

  def execute(state, :jump_forward),
    do: walk(state, JumpList.forward(state.workspace.editing.jump_list), :forward)

  commands(@command_specs)

  command(:jump_list, "Jump list",
    requires_buffer: false,
    execute: &PickerUI.open(&1, MingaEditor.UI.Picker.JumpListSource)
  )

  @doc "Jumps to one jump list entry by its index, as picking a row in `SPC s j` does."
  @spec jump_to_index(state(), non_neg_integer()) :: state()
  def jump_to_index(state, index) when is_integer(index),
    do: walk(state, JumpList.go_to(state.workspace.editing.jump_list, index), :pick)

  @typep step :: {:ok, JumpList.entry(), JumpList.t()} | :none
  @typep direction :: :back | :forward | :pick

  # Follows the entry a step landed on. An entry in a closed buffer is forgotten,
  # and the walk continues in the same direction from where that entry was.
  # Each retry forgets at least one entry, so the walk ends.
  @spec walk(state(), step(), direction()) :: state()
  defp walk(state, :none, _direction), do: state

  defp walk(state, {:ok, {buffer, position}, walked}, direction) do
    case Enum.find_index(state.workspace.buffers.list, &(&1 == buffer)) do
      nil ->
        forgotten = JumpList.forget_buffer(walked, buffer)

        state
        |> Editing.walk_jump_list(forgotten)
        |> walk(step_past_forgotten(forgotten, direction), direction)

      index ->
        state
        |> Editing.walk_jump_list(walked)
        |> follow(buffer, index, position)
    end
  end

  # After forgetting the entry the walk landed on, the list's index is the first entry after it.
  @spec step_past_forgotten(JumpList.t(), direction()) :: step()
  defp step_past_forgotten(jump_list, :forward), do: JumpList.go_to(jump_list, jump_list.index)
  defp step_past_forgotten(jump_list, :back), do: JumpList.go_to(jump_list, jump_list.index - 1)
  defp step_past_forgotten(_jump_list, :pick), do: :none

  @spec follow(state(), pid(), non_neg_integer(), Buffer.position()) :: state()
  defp follow(state, buffer, index, position) do
    state =
      if state.workspace.buffers.active == buffer,
        do: state,
        else: BufferActivation.activate(state, index, record_jump?: false)

    Buffer.move_to(buffer, position)
    %{state | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)}
  end
end
