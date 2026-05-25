defmodule MingaEditor.Commands.InlineEditTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.InlineEdit, as: InlineEditCommand
  alias MingaEditor.InlineEdit.Events, as: InlineEditEvents
  alias MingaEditor.Input.InlineEdit, as: InlineEditInput
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.InlineEdit
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @moduletag :tmp_dir

  test "open requires a visual selection", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex")

    state = InlineEditCommand.open(state)

    assert EditorState.status_msg(state) == "Inline edit requires a visual selection"
    assert state |> EditorState.inline_edits() |> InlineEdit.active(buffer) == nil
  end

  test "open stores selected lines and header", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex", "one\ntwo\nthree")
    Buffer.move_to(buffer, {1, 0})

    state = state |> put_visual_selection({0, 0}) |> InlineEditCommand.open()

    assert %InlineEdit{original_text: "one\ntwo", selection_range: {0, 1}} =
             edit = active_edit(state, buffer)

    assert InlineEdit.header(edit) == "Rewrite lines 1–2. How?"
    assert InlineEdit.agent_prompt(edit) =~ "File: lib/auth.ex"
  end

  test "input handler edits prompt and reject leaves buffer unchanged", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex", "one\ntwo")
    state = state |> put_visual_selection({0, 0}) |> InlineEditCommand.open()
    original = Buffer.content(buffer)

    assert {:handled, state} = InlineEditInput.handle_key(state, ?r, 0)
    assert {:handled, state} = InlineEditInput.handle_key(state, ?x, 0)
    assert active_edit(state, buffer).prompt == "rx"

    assert {:handled, state} = InlineEditInput.handle_key(state, ?n, 0)
    assert active_edit(state, buffer) == nil
    assert Buffer.content(buffer) == original
  end

  test "tool-only rewrite result becomes the proposal", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex", "one\ntwo")
    fake_session = fake_message_session([{:assistant, "Done"}])
    on_exit(fn -> Process.exit(fake_session, :kill) end)

    state = state |> put_visual_selection({0, 0}) |> InlineEditCommand.open()
    edit = active_edit(state, buffer) |> InlineEdit.thinking(fake_session)

    state =
      EditorState.set_inline_edits(state, InlineEdit.put(EditorState.inline_edits(state), edit))

    state =
      InlineEditEvents.handle_event(
        state,
        fake_session,
        {:tool_ended, "produce_rewrite", "ONE", :done}
      )

    state = InlineEditEvents.handle_event(state, fake_session, {:text_delta, "Done"})
    state = InlineEditEvents.handle_event(state, fake_session, {:status_changed, :idle})

    assert active_edit(state, buffer).proposed_rewrite == "ONE"
    assert active_edit(state, buffer).status == :proposed
  end

  test "prompt send failure marks edit failed and clears session", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex", "one\ntwo")
    session_pid = self()

    state = state |> put_visual_selection({0, 0}) |> InlineEditCommand.open()
    edit = active_edit(state, buffer) |> InlineEdit.thinking(session_pid)

    state =
      EditorState.set_inline_edits(state, InlineEdit.put(EditorState.inline_edits(state), edit))

    state = InlineEditEvents.handle_prompt_result(state, session_pid, {:error, :provider_down})

    assert %InlineEdit{
             status: :error,
             session_pid: nil,
             proposed_rewrite: "Failed to rewrite: :provider_down"
           } = active_edit(state, buffer)
  end

  test "accept replaces selected lines and undo restores content", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex", "one\ntwo\nthree")
    Buffer.move_to(buffer, {1, 0})
    state = state |> put_visual_selection({0, 0}) |> InlineEditCommand.open()
    edit = %{active_edit(state, buffer) | proposed_rewrite: "ONE\nTWO"} |> InlineEdit.proposed()

    state =
      EditorState.set_inline_edits(state, InlineEdit.put(EditorState.inline_edits(state), edit))

    assert {:handled, state} = InlineEditInput.handle_key(state, ?y, 0)
    assert active_edit(state, buffer) == nil
    assert Buffer.content(buffer) == "ONE\nTWO\nthree"

    Buffer.undo(buffer)
    assert Buffer.content(buffer) == "one\ntwo\nthree"
  end

  test "accept handles unicode line endings with byte columns", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/unicode.ex", "éé\nthree")
    state = state |> put_visual_selection({0, 0}) |> InlineEditCommand.open()
    edit = %{active_edit(state, buffer) | proposed_rewrite: "X"} |> InlineEdit.proposed()

    state =
      EditorState.set_inline_edits(state, InlineEdit.put(EditorState.inline_edits(state), edit))

    assert {:handled, _state} = InlineEditInput.handle_key(state, ?y, 0)
    assert Buffer.content(buffer) == "X\nthree"
  end

  test "accepting an empty proposal deletes the selected non-final line", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/delete_line.ex", "one\ntwo")
    state = state |> put_visual_selection({0, 0}) |> InlineEditCommand.open()
    edit = %{active_edit(state, buffer) | proposed_rewrite: ""} |> InlineEdit.proposed()

    state =
      EditorState.set_inline_edits(state, InlineEdit.put(EditorState.inline_edits(state), edit))

    assert {:handled, _state} = InlineEditInput.handle_key(state, ?y, 0)
    assert Buffer.content(buffer) == "two"
  end

  test "accept reports read-only buffers without crashing or dismissing", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/readonly.ex", "one\ntwo", read_only: true)
    state = state |> put_visual_selection({0, 0}) |> InlineEditCommand.open()
    edit = %{active_edit(state, buffer) | proposed_rewrite: "ONE"} |> InlineEdit.proposed()

    state =
      EditorState.set_inline_edits(state, InlineEdit.put(EditorState.inline_edits(state), edit))

    assert {:handled, state} = InlineEditInput.handle_key(state, ?y, 0)
    assert EditorState.status_msg(state) == "Inline edit failed: :read_only"
    assert active_edit(state, buffer) != nil
    assert Buffer.content(buffer) == "one\ntwo"
  end

  defp fake_message_session(messages) do
    spawn(fn -> message_session_loop(messages) end)
  end

  defp message_session_loop(messages) do
    receive do
      {:"$gen_call", from, :messages} ->
        GenServer.reply(from, messages)
        message_session_loop(messages)

      :stop ->
        :ok
    end
  end

  defp state_with_file(root, rel_path, content \\ "hello", opts \\ []) do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    {:ok, buffer} =
      start_supervised({BufferProcess, Keyword.merge([content: content, file_path: path], opts)})

    state = %EditorState{
      port_manager: self(),
      workspace:
        %SessionState{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
          windows: %Windows{
            tree: WindowTree.new(1),
            map: %{1 => Window.new(1, buffer, 24, 80)},
            active: 1,
            next_id: 2
          }
        }
        |> SessionState.set_file_tree(%{
          project_root: root,
          tree: nil,
          buffer: nil,
          focused: false
        }),
      shell_state: %TraditionalState{
        tab_bar: TabBar.new(Tab.new_file(1, Path.basename(rel_path)), root)
      }
    }

    {state, buffer}
  end

  defp active_edit(state, buffer) do
    state |> EditorState.inline_edits() |> InlineEdit.active(buffer)
  end

  defp put_visual_selection(state, anchor) do
    visual = %Minga.Mode.VisualState{visual_type: :line, visual_anchor: anchor}

    %{
      state
      | workspace: %{
          state.workspace
          | editing:
              MingaEditor.VimState.transition(state.workspace.editing, :visual_line, visual)
        }
    }
  end
end
