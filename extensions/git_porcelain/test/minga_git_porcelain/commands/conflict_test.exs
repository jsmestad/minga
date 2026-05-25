defmodule MingaGitPorcelain.CommandsConflictTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.NormalPrefixes
  alias MingaGitPorcelain.Commands, as: GitCommands
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    GitStub.ensure_table()
    GitStub.set_root(dir, dir)
    on_exit(fn -> GitStub.clear(dir) end)
    %{root: dir}
  end

  test "]x and [x normal prefixes resolve to merge conflict navigation" do
    trie = NormalPrefixes.trie()

    assert {:prefix, right_bracket} = Bindings.lookup(trie, {?], 0})
    assert {:command, :next_merge_conflict} = Bindings.lookup(right_bracket, {?x, 0})

    assert {:prefix, left_bracket} = Bindings.lookup(trie, {?[, 0})
    assert {:command, :prev_merge_conflict} = Bindings.lookup(left_bracket, {?x, 0})
  end

  test "navigation moves between conflict starts" do
    buffer = start_buffer("before\n" <> conflict("A", "B") <> "\nbetween\n" <> conflict("C", "D"))
    state = state_with_buffer(buffer)

    BufferProcess.move_to(buffer, {0, 0})
    GitCommands.execute(state, :next_merge_conflict)
    assert BufferProcess.cursor(buffer) == {1, 0}

    GitCommands.execute(state, :next_merge_conflict)
    assert BufferProcess.cursor(buffer) == {7, 0}

    GitCommands.execute(state, :prev_merge_conflict)
    assert BufferProcess.cursor(buffer) == {1, 0}
  end

  test "accept current at cursor replaces the conflict block" do
    buffer = start_buffer("before\n" <> conflict("ours", "theirs") <> "\nafter")
    state = state_with_buffer(buffer)

    BufferProcess.move_to(buffer, {2, 0})
    state = GitCommands.execute(state, :git_accept_current_conflict)

    assert BufferProcess.content(buffer) == "before\nours\nafter"
    assert state.shell_state.status_msg == "Resolved all merge conflicts"
  end

  test "click command accepts incoming for the current conflict start line" do
    buffer = start_buffer(conflict("ours", "theirs"))
    state = state_with_buffer(buffer)

    GitCommands.execute(state, {:git_accept_conflict, :incoming, 0})

    assert BufferProcess.content(buffer) == "theirs"
  end

  test "resolving one of multiple conflicts does not save or stage early", %{root: root} do
    path = Path.join(root, "conflict.txt")
    content = two_conflict_content()
    File.write!(path, content)

    buffer = start_supervised!({BufferProcess, [file_path: path]})
    state = state_with_buffer(buffer)

    state = GitCommands.execute(state, {:git_accept_conflict, :current, 0})

    assert BufferProcess.content(buffer) == "ours\nbetween\n" <> conflict("left", "right")
    assert File.read!(path) == content
    assert GitStub.staged_paths(root) == []
    refute_receive {:minga_event, :buffer_saved, _}
    assert state.shell_state.status_msg == "Resolved merge conflict"
  end

  test "click command rejects stale start lines" do
    content = "prefix\n" <> conflict("ours", "theirs")
    buffer = start_buffer(content)
    state = state_with_buffer(buffer)

    state = GitCommands.execute(state, {:git_accept_conflict, :incoming, 0})

    assert BufferProcess.content(buffer) == content
    assert state.shell_state.status_msg == "Merge conflict action is stale"
  end

  test "resolving the final file-backed conflict saves, stages, and publishes buffer_saved", %{
    root: root
  } do
    path = Path.join(root, "conflict.txt")
    File.write!(path, conflict("ours", "theirs"))
    buffer = start_supervised!({BufferProcess, [file_path: path]})
    state = state_with_buffer(buffer)

    Events.subscribe(:buffer_saved)
    on_exit(fn -> Events.unsubscribe(:buffer_saved) end)

    state = GitCommands.execute(state, :git_accept_both_conflict)

    assert_receive {:minga_event, :buffer_saved,
                    %Minga.Events.BufferEvent{buffer: ^buffer, path: ^path}}

    assert File.read!(path) == "ours\ntheirs"
    assert GitStub.staged_paths(root) == ["conflict.txt"]
    assert state.shell_state.status_msg == "Resolved all merge conflicts and staged conflict.txt"
  end

  defp start_buffer(content) do
    start_supervised!({BufferProcess, [content: content]})
  end

  defp state_with_buffer(buffer) do
    %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{list: [buffer], active_index: 0, active: buffer},
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => Window.new(1, buffer, 24, 80)},
          active: 1,
          next_id: 2
        }
      },
      shell_state: %ShellState{}
    }
  end

  defp conflict(current, incoming) do
    "<<<<<<< HEAD\n#{current}\n=======\n#{incoming}\n>>>>>>> branch"
  end

  defp two_conflict_content do
    conflict("ours", "theirs") <> "\nbetween\n" <> conflict("left", "right")
  end
end
