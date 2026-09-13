defmodule MingaEditor.Input.Paste do
  @moduledoc """
  Applies decoded paste input to the focused minibuffer or document input owner.

  Document paste is one bulk buffer edit. Characterwise and linewise visual selections keep their respective Buffer-owned replacement semantics; otherwise text is inserted at the active caret without deleting adjacent text.
  """

  alias Minga.Buffer
  alias Minga.Mode.CommandState
  alias Minga.Mode.EvalState
  alias Minga.Mode.SearchPromptState
  alias Minga.Mode.SearchState
  alias Minga.Mode.VisualState
  alias MingaEditor.Editing
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @typep paste_result :: :ok | {:error, :read_only}

  @doc "Applies a decoded paste to the active text input owner."
  @spec handle(EditorState.t(), String.t()) :: EditorState.t()
  def handle(state, ""), do: state

  def handle(
        %{workspace: %{editing: %{mode: :command, mode_state: %CommandState{}}}} = state,
        text
      ) do
    state
    |> Editing.update_mode_state(fn mode_state ->
      %{mode_state | input: mode_state.input <> text, candidate_index: 0}
    end)
    |> KeyDispatch.refresh_command_completion()
  end

  def handle(
        %{workspace: %{editing: %{mode: :search, mode_state: %SearchState{}}}} = state,
        text
      ) do
    state
    |> Editing.update_mode_state(fn mode_state ->
      %{mode_state | input: mode_state.input <> text}
    end)
    |> MingaEditor.dispatch_command(:incremental_search)
  end

  def handle(
        %{workspace: %{editing: %{mode: :search_prompt, mode_state: %SearchPromptState{}}}} =
          state,
        text
      ) do
    Editing.update_mode_state(state, fn mode_state ->
      %{mode_state | input: mode_state.input <> text}
    end)
  end

  def handle(
        %{workspace: %{editing: %{mode: :eval, mode_state: %EvalState{}}}} = state,
        text
      ) do
    Editing.update_mode_state(state, fn mode_state ->
      %{mode_state | input: mode_state.input <> text}
    end)
  end

  def handle(
        %{
          workspace: %{
            keymap_scope: :editor,
            buffers: %{active: buf},
            editing: %{mode: :visual, mode_state: %VisualState{} = visual_state}
          }
        } = state,
        text
      )
      when is_pid(buf) do
    cursor = Buffer.cursor(buf)

    buf
    |> isolate_undo(fn -> apply_selection_replacement(buf, visual_state, cursor, text) end)
    |> finish_selection_paste(state)
  end

  def handle(%{workspace: %{keymap_scope: :editor, buffers: %{active: buf}}} = state, text)
      when is_pid(buf) do
    buf
    |> isolate_undo(fn -> Buffer.insert_text(buf, text) end)
    |> finish_insertion_paste(state)
  end

  def handle(state, _text), do: state

  @spec isolate_undo(pid(), (-> paste_result())) :: paste_result()
  defp isolate_undo(buf, edit) do
    :ok = Buffer.break_undo_coalescing(buf)
    result = edit.()

    if result == :ok do
      :ok = Buffer.break_undo_coalescing(buf)
    end

    result
  end

  @spec apply_selection_replacement(
          pid(),
          VisualState.t(),
          {non_neg_integer(), non_neg_integer()},
          String.t()
        ) :: paste_result()
  defp apply_selection_replacement(
         buf,
         %VisualState{visual_type: :char, visual_anchor: {start_line, start_col}},
         {end_line, end_col},
         text
       ) do
    Buffer.apply_edit(buf, start_line, start_col, end_line, end_col, text)
  end

  defp apply_selection_replacement(
         buf,
         %VisualState{visual_type: :line, visual_anchor: {start_line, _}},
         {end_line, _},
         text
       ) do
    Buffer.replace_lines(buf, start_line, end_line, text)
  end

  @spec finish_selection_paste(paste_result(), EditorState.t()) :: EditorState.t()
  defp finish_selection_paste(:ok, state) do
    %{
      state
      | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :normal)
    }
  end

  defp finish_selection_paste({:error, :read_only}, state), do: read_only_notice(state)

  @spec finish_insertion_paste(paste_result(), EditorState.t()) :: EditorState.t()
  defp finish_insertion_paste(:ok, %{workspace: %{editing: %{mode: :insert}}} = state) do
    Editing.update_mode_state(state, fn mode_state -> %{mode_state | insert_changed: true} end)
  end

  defp finish_insertion_paste(:ok, state), do: state
  defp finish_insertion_paste({:error, :read_only}, state), do: read_only_notice(state)

  @spec read_only_notice(EditorState.t()) :: EditorState.t()
  defp read_only_notice(state), do: NoticeWorkflow.publish(state, "Buffer is read-only")
end
