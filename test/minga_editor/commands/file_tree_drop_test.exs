defmodule MingaEditor.Commands.FileTreeDropTest do
  @moduledoc "Tests BEAM-owned file-tree drop handling from native GUI intents."

  use Minga.Test.EditorCase, async: true

  alias Minga.Project.FileTree
  alias MingaEditor.Commands
  alias MingaEditor.FileTree.DropIntent

  @moduletag :tmp_dir

  describe "drop/2" do
    test "copies an external file into a directory target", %{tmp_dir: dir} do
      active_file = Path.join(dir, "main.ex")
      target_dir = Path.join(dir, "target")
      File.write!(active_file, "main")
      File.mkdir_p!(target_dir)
      {external_root, external_file} = external_file_fixture(dir, "external.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, active_file)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [external_file])

      state = Commands.FileTree.drop(state, intent)

      assert File.exists?(Path.join(target_dir, "external.txt"))
      assert state.workspace.file_tree.tree != nil
    end

    test "copies an external file to the parent directory when dropped onto a file", %{
      tmp_dir: dir
    } do
      target_file = Path.join(dir, "main.ex")
      File.write!(target_file, "main")
      {external_root, external_file} = external_file_fixture(dir, "onto-file.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, target_file)
      intent = drop_intent(state.workspace.file_tree.tree, target_file, [external_file])

      _state = Commands.FileTree.drop(state, intent)

      assert File.exists?(Path.join(dir, "onto-file.txt"))
    end

    test "rejects stale target identity without copying", %{tmp_dir: dir} do
      active_file = Path.join(dir, "main.ex")
      target_dir = Path.join(dir, "target")
      File.write!(active_file, "main")
      File.mkdir_p!(target_dir)
      {external_root, external_file} = external_file_fixture(dir, "stale.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, active_file)

      intent =
        state.workspace.file_tree.tree
        |> drop_intent(target_dir, [external_file])
        |> Map.put(:target_id, "/project/stale-target")

      _state = Commands.FileTree.drop(state, intent)

      refute File.exists?(Path.join(target_dir, "stale.txt"))
    end

    test "moves an internal visible source into a directory target", %{tmp_dir: dir} do
      active_file = Path.join(dir, "main.ex")
      source_file = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "target")
      File.write!(active_file, "main")
      File.write!(source_file, "source")
      File.mkdir_p!(target_dir)

      state = open_file_tree(dir, active_file)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [source_file])

      _state = Commands.FileTree.drop(state, intent)

      refute File.exists?(source_file)
      assert File.exists?(Path.join(target_dir, "source.txt"))
    end

    test "moves an internal visible source to the parent directory when dropped onto a file", %{
      tmp_dir: dir
    } do
      source_file = Path.join(dir, "source.txt")
      nested_dir = Path.join(dir, "nested")
      target_file = Path.join(nested_dir, "main.ex")
      File.write!(source_file, "source")
      File.mkdir_p!(nested_dir)
      File.write!(target_file, "main")

      state = open_file_tree(dir, target_file)
      intent = drop_intent(state.workspace.file_tree.tree, target_file, [source_file])

      _state = Commands.FileTree.drop(state, intent)

      refute File.exists?(source_file)
      assert File.exists?(Path.join(nested_dir, "source.txt"))
    end

    test "does not overwrite an existing destination for an internal source", %{tmp_dir: dir} do
      active_file = Path.join(dir, "main.ex")
      source_file = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "target")
      existing_dest = Path.join(target_dir, "source.txt")
      File.write!(active_file, "main")
      File.write!(source_file, "source")
      File.mkdir_p!(target_dir)
      File.write!(existing_dest, "existing")

      state = open_file_tree(dir, active_file)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [source_file])

      _state = Commands.FileTree.drop(state, intent)

      assert File.read!(source_file) == "source"
      assert File.read!(existing_dest) == "existing"
    end

    test "does not overwrite a dangling symlink destination for an internal source", %{
      tmp_dir: dir
    } do
      active_file = Path.join(dir, "main.ex")
      source_file = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "target")
      dangling_dest = Path.join(target_dir, "source.txt")
      File.write!(active_file, "main")
      File.write!(source_file, "source")
      File.mkdir_p!(target_dir)
      File.ln_s!("missing.txt", dangling_dest)

      state = open_file_tree(dir, active_file)
      intent = drop_intent(state.workspace.file_tree.tree, target_dir, [source_file])

      _state = Commands.FileTree.drop(state, intent)

      assert File.read!(source_file) == "source"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(dangling_dest)
    end
  end

  defp open_file_tree(dir, active_file) do
    ctx = start_editor("main", file_path: active_file, project_root: dir)
    send_keys_sync(ctx, "<SPC>op")
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
