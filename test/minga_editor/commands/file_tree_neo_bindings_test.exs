defmodule MingaEditor.Commands.FileTreeNeoBindingsTest do
  @moduledoc """
  Regression tests for neo-tree-style file tree commands.
  """
  use ExUnit.Case, async: true

  import Hammox

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias Minga.Project.FileTree
  alias MingaEditor.Commands.FileTree, as: FileTreeCommands
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState

  setup :verify_on_exit!

  setup do
    test_pid = self()

    stub(Minga.Clipboard.Mock, :write, fn text ->
      send(test_pid, {:clipboard_written, text})
      :ok
    end)

    stub(Minga.Clipboard.Mock, :read, fn -> nil end)

    :ok
  end

  describe "copy path" do
    @tag :tmp_dir
    test "copies selected entry absolute path to the system clipboard", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "alpha.txt")
      File.write!(path, "alpha")

      state = build_state(tmp_dir)

      FileTreeCommands.copy_path(state)

      assert_receive {:clipboard_written, ^path}, 200
    end
  end

  describe "copy, move, and paste" do
    @tag :tmp_dir
    test "copies marked file into selected directory", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "alpha.txt")
      target_dir = Path.join(tmp_dir, "dest")
      File.write!(source, "alpha")
      File.mkdir_p!(target_dir)

      state =
        tmp_dir |> build_state() |> select_entry("alpha.txt") |> FileTreeCommands.mark_copy()

      state = state |> select_entry("dest") |> FileTreeCommands.paste()

      assert File.read!(Path.join(target_dir, "alpha.txt")) == "alpha"
      assert ft(state).clipboard_mark.operation == :copy
    end

    @tag :tmp_dir
    test "moves marked file into selected directory and clears move mark", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "alpha.txt")
      target_dir = Path.join(tmp_dir, "dest")
      File.write!(source, "alpha")
      File.mkdir_p!(target_dir)

      state =
        tmp_dir |> build_state() |> select_entry("alpha.txt") |> FileTreeCommands.mark_move()

      state = state |> select_entry("dest") |> FileTreeCommands.paste()

      refute File.exists?(source)
      assert File.read!(Path.join(target_dir, "alpha.txt")) == "alpha"
      assert ft(state).clipboard_mark == nil
    end

    @tag :tmp_dir
    test "moves a dirty open file buffer without saving it during retarget", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "alpha.txt")
      target_dir = Path.join(tmp_dir, "dest")
      target = Path.join(target_dir, "alpha.txt")
      File.write!(source, "alpha")
      File.mkdir_p!(target_dir)

      buffer = start_supervised!({BufferProcess, file_path: source})
      BufferProcess.replace_content(buffer, "dirty", :user)
      assert BufferProcess.dirty?(buffer)

      state =
        tmp_dir
        |> build_state(Buffers.add(%Buffers{}, buffer))
        |> select_entry("alpha.txt")
        |> FileTreeCommands.mark_move()

      state = state |> select_entry("dest") |> FileTreeCommands.paste()

      assert BufferProcess.file_path(buffer) == target
      assert BufferProcess.dirty?(buffer)
      assert :not_found = BufferProcess.pid_for_path(source)
      assert {:ok, ^buffer} = BufferProcess.pid_for_path(target)
      assert File.read!(target) == "alpha"
      refute File.exists?(source)

      assert :ok = BufferProcess.save(buffer)
      assert File.read!(target) == "dirty"
      assert ft(state).clipboard_mark == nil
    end

    @tag :tmp_dir
    test "moves a buffer tracked only in an inactive tab snapshot", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "alpha.txt")
      target_dir = Path.join(tmp_dir, "dest")
      target = Path.join(target_dir, "alpha.txt")
      File.write!(source, "source")
      File.mkdir_p!(target_dir)

      target_buffer = start_supervised!({BufferProcess, file_path: source})

      active_buffer =
        start_supervised!(%{
          id: {:active_buffer, System.unique_integer([:positive])},
          start:
            {BufferProcess, :start_link,
             [[content: "active", buffer_name: "active-#{System.unique_integer([:positive])}"]]},
          restart: :temporary
        })

      {:ok, old_ref} = FileRef.from_path(tmp_dir, source)
      {:ok, new_ref} = FileRef.from_path(tmp_dir, target)
      {:ok, active_ref} = FileRef.from_path(tmp_dir, "active.txt")

      inactive_workspace = %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: target_buffer, list: [target_buffer], active_index: 0}
      }

      active_workspace = %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: active_buffer, list: [active_buffer], active_index: 0}
      }

      inactive_tab =
        Tab.new_file(1, "alpha.txt")
        |> Tab.set_file_ref(old_ref)
        |> Tab.set_context(SessionState.to_tab_context(inactive_workspace))

      {tab_bar, active_tab} = TabBar.add(TabBar.new(inactive_tab, tmp_dir), :file, "active.txt")

      tab_bar =
        tab_bar
        |> TabBar.update_tab(active_tab.id, fn tab ->
          tab
          |> Tab.set_file_ref(active_ref)
          |> Tab.set_context(SessionState.to_tab_context(active_workspace))
        end)
        |> TabBar.update_workspace(0, fn ws ->
          WorkspaceModel.add_file(ws, active_ref) |> WorkspaceModel.set_active_file(active_ref)
        end)

      state =
        tmp_dir
        |> build_state(Buffers.add(%Buffers{}, active_buffer))
        |> EditorState.update_shell_state(fn _ -> %ShellState{tab_bar: tab_bar} end)
        |> select_entry("alpha.txt")
        |> FileTreeCommands.mark_move()

      state = state |> select_entry("dest") |> FileTreeCommands.paste()

      assert BufferProcess.file_path(target_buffer) == target
      assert File.read!(target) == "source"
      assert {:ok, ^target_buffer} = BufferProcess.pid_for_path(target)
      assert TabBar.active(state.shell_state.tab_bar).id == active_tab.id
      assert TabBar.get(state.shell_state.tab_bar, inactive_tab.id).file_ref == new_ref
      assert TabBar.get_workspace(state.shell_state.tab_bar, 0).active_file == active_ref
      assert WorkspaceModel.has_file?(TabBar.get_workspace(state.shell_state.tab_bar, 0), new_ref)
      refute WorkspaceModel.has_file?(TabBar.get_workspace(state.shell_state.tab_bar, 0), old_ref)
    end

    @tag :tmp_dir
    test "move failure on existing destination leaves source, target, and mark intact", %{
      tmp_dir: tmp_dir
    } do
      source = Path.join(tmp_dir, "alpha.txt")
      target_dir = Path.join(tmp_dir, "dest")
      target = Path.join(target_dir, "alpha.txt")
      File.write!(source, "source")
      File.mkdir_p!(target_dir)
      File.write!(target, "existing")

      state =
        tmp_dir |> build_state() |> select_entry("alpha.txt") |> FileTreeCommands.mark_move()

      state = state |> select_entry("dest") |> FileTreeCommands.paste()

      assert File.read!(source) == "source"
      assert File.read!(target) == "existing"
      assert ft(state).clipboard_mark.operation == :move
    end

    @tag :tmp_dir
    test "move failure into a descendant keeps the directory and mark intact", %{tmp_dir: tmp_dir} do
      source_dir = Path.join(tmp_dir, "src")
      child_dir = Path.join(source_dir, "child")
      File.mkdir_p!(child_dir)
      File.write!(Path.join(source_dir, "file.txt"), "content")

      state =
        tmp_dir
        |> build_state()
        |> expand_path(source_dir)
        |> select_entry("src")
        |> FileTreeCommands.mark_move()

      state = state |> select_entry("child") |> FileTreeCommands.paste()

      refute File.exists?(Path.join(child_dir, "src"))
      assert File.exists?(source_dir)
      assert ft(state).clipboard_mark.operation == :move
    end

    @tag :tmp_dir
    test "successful move retargets an open buffer path and saves to the new path", %{
      tmp_dir: tmp_dir
    } do
      source = Path.join(tmp_dir, "alpha.txt")
      target_dir = Path.join(tmp_dir, "dest")
      target = Path.join(target_dir, "alpha.txt")
      File.write!(source, "source")
      File.mkdir_p!(target_dir)

      buffer = start_supervised!({BufferProcess, file_path: source})
      {:ok, old_ref} = FileRef.from_path(tmp_dir, source)
      {:ok, new_ref} = FileRef.from_path(tmp_dir, target)

      state =
        tmp_dir
        |> build_state(Buffers.add(%Buffers{}, buffer))
        |> set_buffer_file_tab(old_ref, tmp_dir)
        |> select_entry("alpha.txt")
        |> FileTreeCommands.mark_move()

      state = state |> select_entry("dest") |> FileTreeCommands.paste()

      assert BufferProcess.file_path(buffer) == target
      assert File.read!(target) == "source"
      assert TabBar.active(state.shell_state.tab_bar).file_ref == new_ref
      assert TabBar.get_workspace(state.shell_state.tab_bar, 0).active_file == new_ref
      assert WorkspaceModel.has_file?(TabBar.get_workspace(state.shell_state.tab_bar, 0), new_ref)
      refute WorkspaceModel.has_file?(TabBar.get_workspace(state.shell_state.tab_bar, 0), old_ref)

      BufferProcess.replace_content(buffer, "updated", :user)
      assert :ok = BufferProcess.save(buffer)

      assert File.read!(target) == "updated"
      refute File.exists?(source)
    end

    @tag :tmp_dir
    test "failed move keeps the clipboard mark for retry", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "retry.txt")
      target_dir = Path.join(tmp_dir, "dest")
      File.write!(source, "retry")
      File.mkdir_p!(target_dir)
      File.write!(Path.join(target_dir, "retry.txt"), "existing")

      state =
        tmp_dir |> build_state() |> select_entry("retry.txt") |> FileTreeCommands.mark_move()

      state = state |> select_entry("dest") |> FileTreeCommands.paste()

      assert ft(state).clipboard_mark.operation == :move
    end

    @tag :tmp_dir
    test "copy paste rejects directory destinations inside the source", %{tmp_dir: tmp_dir} do
      source_dir = Path.join(tmp_dir, "src")
      child_dir = Path.join(source_dir, "child")
      File.mkdir_p!(child_dir)
      File.write!(Path.join(source_dir, "file.txt"), "content")

      state =
        tmp_dir
        |> build_state()
        |> expand_path(source_dir)
        |> select_entry("src")
        |> FileTreeCommands.mark_copy()

      state = state |> select_entry("child") |> FileTreeCommands.paste()

      refute File.exists?(Path.join(child_dir, "src"))
      assert ft(state).clipboard_mark.operation == :copy
    end

    @tag :tmp_dir
    test "copy paste into selected file uses the file parent directory", %{tmp_dir: tmp_dir} do
      source_dir = Path.join(tmp_dir, "src")
      source = Path.join(source_dir, "alpha.txt")
      File.mkdir_p!(source_dir)
      File.write!(source, "alpha")
      File.write!(Path.join(tmp_dir, "target.txt"), "target")

      state =
        tmp_dir
        |> build_state()
        |> expand_path(source_dir)
        |> select_entry("alpha.txt")
        |> FileTreeCommands.mark_copy()

      state |> select_entry("target.txt") |> FileTreeCommands.paste()

      assert File.read!(Path.join(tmp_dir, "alpha.txt")) == "alpha"
    end

    @tag :tmp_dir
    test "moves a dirty open descendant buffer when renaming a directory", %{tmp_dir: tmp_dir} do
      source_dir = Path.join(tmp_dir, "src")
      source_file = Path.join([source_dir, "nested", "alpha.txt"])
      target_dir = Path.join(tmp_dir, "dest")
      target_file = Path.join([target_dir, "src", "nested", "alpha.txt"])
      File.mkdir_p!(Path.dirname(source_file))
      File.write!(source_file, "alpha")
      File.mkdir_p!(target_dir)

      buffer = start_supervised!({BufferProcess, file_path: source_file})
      BufferProcess.replace_content(buffer, "dirty", :user)
      assert BufferProcess.dirty?(buffer)

      state =
        tmp_dir
        |> build_state(Buffers.add(%Buffers{}, buffer))
        |> expand_path(source_dir)
        |> select_entry("src")
        |> FileTreeCommands.mark_move()

      state = state |> select_entry("dest") |> FileTreeCommands.paste()

      assert BufferProcess.file_path(buffer) == target_file
      assert BufferProcess.dirty?(buffer)
      assert File.read!(target_file) == "alpha"
      refute File.exists?(source_file)
      refute File.exists?(source_dir)
      assert {:ok, ^buffer} = BufferProcess.pid_for_path(target_file)
      assert :not_found = BufferProcess.pid_for_path(source_file)

      assert :ok = BufferProcess.save(buffer)
      assert File.read!(target_file) == "dirty"
      assert ft(state).clipboard_mark == nil
    end

    @tag :tmp_dir
    test "copy paste does not overwrite an existing destination", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "alpha.txt"), "source")
      target_dir = Path.join(tmp_dir, "dest")
      File.mkdir_p!(target_dir)
      File.write!(Path.join(target_dir, "alpha.txt"), "existing")

      state =
        tmp_dir |> build_state() |> select_entry("alpha.txt") |> FileTreeCommands.mark_copy()

      state |> select_entry("dest") |> FileTreeCommands.paste()

      assert File.read!(Path.join(target_dir, "alpha.txt")) == "existing"
    end

    @tag :tmp_dir
    test "copy paste recursively copies directories", %{tmp_dir: tmp_dir} do
      source_dir = Path.join(tmp_dir, "src")
      File.mkdir_p!(Path.join(source_dir, "nested"))
      File.write!(Path.join([source_dir, "nested", "file.txt"]), "content")
      target_dir = Path.join(tmp_dir, "dest")
      File.mkdir_p!(target_dir)

      state = tmp_dir |> build_state() |> select_entry("src") |> FileTreeCommands.mark_copy()
      state |> select_entry("dest") |> FileTreeCommands.paste()

      assert File.read!(Path.join([target_dir, "src", "nested", "file.txt"])) == "content"
    end
  end

  describe "re-rooting" do
    @tag :tmp_dir
    test "root_parent changes root to parent directory", %{tmp_dir: tmp_dir} do
      child = Path.join(tmp_dir, "child")
      File.mkdir_p!(child)
      state = build_state(child)

      state = FileTreeCommands.root_parent(state)

      assert ft(state).tree.root == Path.expand(tmp_dir)
      assert ft(state).original_root == Path.expand(child)
    end

    @tag :tmp_dir
    test "root_selected changes root to selected directory and root_original resets it", %{
      tmp_dir: tmp_dir
    } do
      child = Path.join(tmp_dir, "child")
      File.mkdir_p!(child)
      File.write!(Path.join(tmp_dir, "alpha.txt"), "alpha")

      state =
        tmp_dir |> build_state() |> select_entry("child") |> FileTreeCommands.root_selected()

      assert ft(state).tree.root == Path.expand(child)

      state = FileTreeCommands.root_original(state)
      assert ft(state).tree.root == Path.expand(tmp_dir)
    end
  end

  describe "filter and help state" do
    @tag :tmp_dir
    test "filter starts filtering and narrows visible entries", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "alpha.txt"), "alpha")
      File.write!(Path.join(tmp_dir, "beta.txt"), "beta")

      state = tmp_dir |> build_state() |> FileTreeCommands.filter()
      file_tree = FileTreeState.update_filter(ft(state), "alpha")

      assert file_tree.filtering == true
      assert Enum.map(FileTree.visible_entries(file_tree.tree), & &1.name) == ["alpha.txt"]
    end

    @tag :tmp_dir
    test "toggle_help flips help overlay visibility", %{tmp_dir: tmp_dir} do
      state = build_state(tmp_dir)

      state = FileTreeCommands.toggle_help(state)
      assert ft(state).help_visible == true

      state = FileTreeCommands.toggle_help(state)
      assert ft(state).help_visible == false
    end
  end

  defp set_buffer_file_tab(%EditorState{} = state, file_ref, root) do
    tab =
      Tab.new_file(1, Path.basename(file_ref.display_name))
      |> Tab.set_file_ref(file_ref)
      |> Tab.set_context(SessionState.to_tab_context(state.workspace))

    tab_bar =
      TabBar.new(tab, root)
      |> TabBar.update_workspace(0, fn ws -> WorkspaceModel.set_active_file(ws, file_ref) end)

    EditorState.update_shell_state(state, fn _ -> %ShellState{tab_bar: tab_bar} end)
  end

  defp build_state(root, buffers \\ %Buffers{}) do
    tree = root |> FileTree.new() |> FileTree.refresh()

    %EditorState{
      port_manager: nil,
      workspace:
        %SessionState{buffers: buffers, viewport: Viewport.new(24, 80)}
        |> SessionState.set_file_tree(FileTreeState.open(%FileTreeState{}, tree, nil))
    }
  end

  defp ft(state), do: EditorState.file_tree_state(state)

  defp expand_path(state, path) do
    tree = FileTree.expand_path(ft(state).tree, path)
    file_tree = FileTreeState.replace_tree(ft(state), tree)
    EditorState.set_file_tree(state, file_tree)
  end

  defp select_entry(state, name) do
    entries = FileTree.visible_entries(ft(state).tree)
    index = Enum.find_index(entries, &(&1.name == name))
    refute index == nil

    tree = FileTree.select(ft(state).tree, index)
    file_tree = FileTreeState.replace_tree(ft(state), tree)
    EditorState.set_file_tree(state, file_tree)
  end
end
