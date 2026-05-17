defmodule MingaEditor.Commands.FileTreeDropTest do
  @moduledoc """
  Command-state tests for BEAM-owned file-tree drop handling from native GUI intents.

  Classification: these tests call `Commands.FileTree.drop/2` directly on constructed editor state. They still verify filesystem-visible behavior, stale-target rejection, overwrite protection, and open-buffer retargeting without booting the full EditorCase input/render stack.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Events
  alias Minga.Project.FileTree
  alias MingaEditor.Commands
  alias MingaEditor.FileTree.DropIntent
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  @moduletag :tmp_dir

  setup context do
    events_registry = private_events_registry(context)
    start_supervised!({Events, name: events_registry})
    {:ok, events_registry: events_registry}
  end

  describe "[command-state] drop/2 filesystem effects" do
    test "copies an external file into a directory target", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_dir = Path.join(dir, "target")
      File.mkdir_p!(target_dir)
      {external_root, external_file} = external_file_fixture(dir, "external.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [external_file])

      state = Commands.FileTree.drop(state, intent)

      assert File.read!(Path.join(target_dir, "external.txt")) == "external"
      assert state.workspace.file_tree.tree != nil
    end

    test "copies an external file to the parent directory when dropped onto a file", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_file = Path.join(dir, "main.ex")
      File.write!(target_file, "main")
      {external_root, external_file} = external_file_fixture(dir, "onto-file.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(state.workspace.file_tree.tree, target_file, [external_file])

      _state = Commands.FileTree.drop(state, intent)

      assert File.read!(Path.join(dir, "onto-file.txt")) == "external"
    end

    test "moves an internal visible source into a directory target", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source_file = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "target")
      File.write!(source_file, "source")
      File.mkdir_p!(target_dir)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [source_file])

      _state = Commands.FileTree.drop(state, intent)

      refute File.exists?(source_file)
      assert File.read!(Path.join(target_dir, "source.txt")) == "source"
    end

    test "moves an internal symlink entry instead of copying its external target", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_dir = Path.join(dir, "target")
      symlink_path = Path.join(dir, "linked.txt")
      {external_root, external_file} = external_file_fixture(dir, "linked-target.txt")
      on_exit(fn -> File.rm_rf(external_root) end)
      File.mkdir_p!(target_dir)
      File.ln_s!(external_file, symlink_path)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [symlink_path])

      _state = Commands.FileTree.drop(state, intent)

      assert {:error, :enoent} = File.lstat(symlink_path)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(target_dir, "linked.txt"))
      assert File.read!(external_file) == "external"
    end

    test "moves an internal visible source to the parent directory when dropped onto a file", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source_file = Path.join(dir, "source.txt")
      nested_dir = Path.join(dir, "nested")
      target_file = Path.join(nested_dir, "main.ex")
      File.write!(source_file, "source")
      File.mkdir_p!(nested_dir)
      File.write!(target_file, "main")

      state = open_file_tree(dir, events_registry, target_file)
      intent = drop_intent(state.workspace.file_tree.tree, target_file, [source_file])

      _state = Commands.FileTree.drop(state, intent)

      refute File.exists?(source_file)
      assert File.read!(Path.join(nested_dir, "source.txt")) == "source"
    end
  end

  describe "[command-state] drop/2 rejection and retargeting" do
    test "rejects stale target identity without copying", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_dir = Path.join(dir, "target")
      File.mkdir_p!(target_dir)
      {external_root, external_file} = external_file_fixture(dir, "stale.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, events_registry)

      intent =
        state.workspace.file_tree.tree
        |> drop_intent(target_dir, [external_file])
        |> Map.put(:target_id, "/project/stale-target")

      _state = Commands.FileTree.drop(state, intent)

      refute File.exists?(Path.join(target_dir, "stale.txt"))
    end

    test "does not overwrite an existing destination for an internal source", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source_file = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "target")
      existing_dest = Path.join(target_dir, "source.txt")
      File.write!(source_file, "source")
      File.mkdir_p!(target_dir)
      File.write!(existing_dest, "existing")

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [source_file])

      _state = Commands.FileTree.drop(state, intent)

      assert File.read!(source_file) == "source"
      assert File.read!(existing_dest) == "existing"
    end

    test "does not overwrite a dangling symlink destination for an internal source", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source_file = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "target")
      dangling_dest = Path.join(target_dir, "source.txt")
      File.write!(source_file, "source")
      File.mkdir_p!(target_dir)
      File.ln_s!("missing.txt", dangling_dest)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [source_file])

      _state = Commands.FileTree.drop(state, intent)

      assert File.read!(source_file) == "source"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(dangling_dest)
      refute File.exists?(Path.join(target_dir, "missing.txt"))
    end

    test "does not copy through a dangling symlink destination for an external source", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_dir = Path.join(dir, "target")
      dangling_dest = Path.join(target_dir, "external.txt")
      File.mkdir_p!(target_dir)
      File.ln_s!("missing.txt", dangling_dest)
      {external_root, external_file} = external_file_fixture(dir, "external.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [external_file])

      _state = Commands.FileTree.drop(state, intent)

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(dangling_dest)
      refute File.exists?(Path.join(target_dir, "missing.txt"))
    end

    test "retargets open buffers under an internally moved directory", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source_dir = Path.join(dir, "source")
      target_dir = Path.join(dir, "target")
      active_file = Path.join(source_dir, "main.ex")
      moved_file = Path.join([target_dir, "source", "main.ex"])
      File.mkdir_p!(source_dir)
      File.mkdir_p!(target_dir)
      File.write!(active_file, "main")

      state = open_file_tree(dir, events_registry, active_file)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [source_dir])

      _state = Commands.FileTree.drop(state, intent)

      refute File.exists?(active_file)
      assert File.exists?(moved_file)
      assert Buffer.file_path(state.workspace.buffers.active) == moved_file
    end
  end

  defp open_file_tree(dir, events_registry, active_file \\ nil) do
    tree = reveal_active_file(FileTree.new(dir), active_file)
    buffers = buffers_for_active_file(active_file, events_registry)

    %EditorState{
      port_manager: self(),
      events_registry: events_registry,
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: buffers,
        file_tree: FileTreeState.open(%FileTreeState{}, tree, nil),
        keymap_scope: :file_tree
      }
    }
  end

  defp private_events_registry(%{module: module, test: test}) do
    Module.concat([module, test, Events])
  end

  defp reveal_active_file(tree, nil), do: tree
  defp reveal_active_file(tree, active_file), do: FileTree.reveal(tree, active_file)

  defp buffers_for_active_file(nil, _events_registry), do: %Buffers{}

  defp buffers_for_active_file(active_file, events_registry) do
    buffer = start_supervised!({Buffer, file_path: active_file, events_registry: events_registry})
    Buffers.add(%Buffers{}, buffer)
  end

  defp external_file_fixture(dir, name) do
    root = Path.join(Path.dirname(dir), "external-drop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, name)
    File.write!(path, "external")
    {root, path}
  end

  defp drop_intent(%FileTree{} = tree, target_path, source_paths) do
    entries = FileTree.visible_entries(tree)

    {target, index} =
      entries
      |> Enum.with_index()
      |> Enum.find(fn {entry, _index} -> Path.expand(entry.path) == Path.expand(target_path) end)

    DropIntent.new(
      source_paths: source_paths,
      target_index: index,
      target_id: Path.expand(target.path),
      target_path_hash: :erlang.phash2(Path.expand(target.path), 0xFFFFFFFF),
      target_path: target.path,
      target_dir?: target.dir?,
      modifiers: 0
    )
  end
end
