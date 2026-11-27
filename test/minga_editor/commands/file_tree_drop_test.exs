defmodule MingaEditor.Commands.FileTreeDropTest do
  @moduledoc """
  Command-state tests for BEAM-owned file-tree drop handling from native GUI intents.

  Classification: these tests call `Commands.FileTree.drop/2` directly on constructed editor state. They still verify filesystem-visible behavior, stale-target rejection, overwrite protection, and open-buffer retargeting without booting the full EditorCase input/render stack.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Events
  alias Minga.Project.FileTree
  alias Minga.Test.FileTreeCopyFixture, as: CopyFixture
  alias MingaEditor.Commands
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Copy
  alias MingaEditor.FileTree.DropIntent
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Session.State, as: SessionState

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
      target_dir = Path.join(dir, "dropzone")
      File.mkdir_p!(target_dir)
      {external_root, external_file} = external_file_fixture(dir, "external.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(tree(state), target_dir, [external_file])

      state = state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy()

      assert File.read!(Path.join(target_dir, "external.txt")) == "external"
      assert tree(state) != nil
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
      intent = drop_intent(tree(state), target_file, [external_file])

      state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy()

      assert File.read!(Path.join(dir, "onto-file.txt")) == "external"
    end

    test "processes all external items in one drop even if an earlier item collides", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_dir = Path.join(dir, "dropzone")
      File.mkdir!(target_dir)
      {external_root, blocked} = external_file_fixture(dir, "blocked.txt")
      on_exit(fn -> File.rm_rf(external_root) end)
      existing = Path.join(target_dir, "blocked.txt")
      File.write!(existing, "preserve")
      file = Path.join(external_root, "later.txt")
      File.write!(file, "later")
      folder = Path.join(external_root, "folder")
      File.mkdir_p!(Path.join(folder, "nested"))
      File.write!(Path.join(folder, "nested/child.txt"), "child")
      internal = Path.join(dir, "internal.txt")
      File.write!(internal, "move")

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(tree(state), target_dir, [blocked, file, internal, folder])
      result = state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy(:failed)

      refute File.exists?(internal)
      assert File.read!(Path.join(target_dir, "internal.txt")) == "move"

      assert File.read!(existing) == "preserve"
      assert File.read!(Path.join(target_dir, "later.txt")) == "later"
      assert File.read!(Path.join(target_dir, "folder/nested/child.txt")) == "child"
      assert {:debounced, _token, 0} = ft(result).refresh.phase
    end

    for first <- [:external, :internal] do
      @first first

      test "the first #{first} item wins a mixed drop with matching basenames", %{
        tmp_dir: dir,
        events_registry: events_registry
      } do
        target_dir = Path.join(dir, "dropzone")
        internal = Path.join(dir, "shared.txt")
        File.mkdir!(target_dir)
        File.write!(internal, "internal")
        {external_root, external} = external_file_fixture(dir, "shared.txt")
        on_exit(fn -> File.rm_rf(external_root) end)

        {sources, winning_bytes} =
          case @first do
            :external -> {[external, internal], "external"}
            :internal -> {[internal, external], "internal"}
          end

        state = open_file_tree(dir, events_registry)
        intent = drop_intent(tree(state), target_dir, sources)
        state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy(:failed)

        assert File.read!(Path.join(target_dir, "shared.txt")) == winning_bytes
        assert File.read!(external) == "external"

        case @first do
          :external -> assert File.read!(internal) == "internal"
          :internal -> refute File.exists?(internal)
        end
      end
    end

    test "a busy mutation lane rejects the entire mixed drop before either item changes disk", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_dir = Path.join(dir, "dropzone")
      internal = Path.join(dir, "internal.txt")
      blocker = Path.join(dir, "blocker.txt")
      File.mkdir!(target_dir)
      File.write!(internal, "internal")
      File.write!(blocker, "blocker")
      {external_root, external} = external_file_fixture(dir, "external.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, events_registry)
      scheduler = state.effect_scheduler
      state = Copy.duplicate(state, blocker)
      outcome = CopyFixture.take_copy(scheduler, :completed)

      assert EffectScheduler.active_activity?(scheduler, :file_tree_mutation)
      intent = drop_intent(tree(state), target_dir, [internal, external])
      result = Commands.FileTree.drop(state, intent)

      assert result.shell_runtime.state.notice.message =~ "mutation is already running"
      assert File.read!(internal) == "internal"
      assert File.ls!(target_dir) == []
      assert EffectScheduler.stats(scheduler).admitted == 1
      EffectScheduler.finalize(scheduler, outcome)
    end

    test "moves an internal visible source into a directory target", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source_file = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "dropzone")
      File.write!(source_file, "source")
      File.mkdir_p!(target_dir)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(tree(state), target_dir, [source_file])

      state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy()

      refute File.exists?(source_file)
      assert File.read!(Path.join(target_dir, "source.txt")) == "source"
    end

    test "moves an internal symlink entry instead of copying its external target", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_dir = Path.join(dir, "dropzone")
      symlink_path = Path.join(dir, "linked.txt")
      {external_root, external_file} = external_file_fixture(dir, "linked-target.txt")
      on_exit(fn -> File.rm_rf(external_root) end)
      File.mkdir_p!(target_dir)
      File.ln_s!(external_file, symlink_path)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(tree(state), target_dir, [symlink_path])

      state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy()

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
      intent = drop_intent(tree(state), target_file, [source_file])

      state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy()

      refute File.exists?(source_file)
      assert File.read!(Path.join(nested_dir, "source.txt")) == "source"
    end
  end

  describe "[command-state] drop/2 rejection and retargeting" do
    test "rejects stale target identity without copying", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_dir = Path.join(dir, "dropzone")
      File.mkdir_p!(target_dir)
      {external_root, external_file} = external_file_fixture(dir, "stale.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, events_registry)

      intent =
        tree(state)
        |> drop_intent(target_dir, [external_file])
        |> Map.put(:target_id, "/project/stale-target")

      ^state = Commands.FileTree.drop(state, intent)
      assert EffectScheduler.stats(state.effect_scheduler).admitted == 0

      refute File.exists?(Path.join(target_dir, "stale.txt"))
    end

    test "rejects a nonresident path under the root without treating it as external", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      hidden_parent = Path.join(dir, "collapsed")
      source = Path.join(hidden_parent, "hidden.txt")
      target = Path.join(dir, "dropzone")
      File.mkdir!(hidden_parent)
      File.mkdir!(target)
      File.write!(source, "untouched")

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(tree(state), target, [source])
      state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy(:failed)

      assert File.read!(source) == "untouched"
      assert File.ls!(target) == []
    end

    test "does not overwrite an existing destination for an internal source", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source_file = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "dropzone")
      existing_dest = Path.join(target_dir, "source.txt")
      File.write!(source_file, "source")
      File.mkdir_p!(target_dir)
      File.write!(existing_dest, "existing")

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(tree(state), target_dir, [source_file])

      state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy(:failed)

      assert File.read!(source_file) == "source"
      assert File.read!(existing_dest) == "existing"
    end

    test "does not overwrite a dangling symlink destination for an internal source", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source_file = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "dropzone")
      dangling_dest = Path.join(target_dir, "source.txt")
      File.write!(source_file, "source")
      File.mkdir_p!(target_dir)
      File.ln_s!("missing.txt", dangling_dest)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(tree(state), target_dir, [source_file])

      state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy(:failed)

      assert File.read!(source_file) == "source"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(dangling_dest)
      refute File.exists?(Path.join(target_dir, "missing.txt"))
    end

    test "does not copy through a dangling symlink destination for an external source", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      target_dir = Path.join(dir, "dropzone")
      dangling_dest = Path.join(target_dir, "external.txt")
      File.mkdir_p!(target_dir)
      File.ln_s!("missing.txt", dangling_dest)
      {external_root, external_file} = external_file_fixture(dir, "external.txt")
      on_exit(fn -> File.rm_rf(external_root) end)

      state = open_file_tree(dir, events_registry)
      intent = drop_intent(tree(state), target_dir, [external_file])

      state |> Commands.FileTree.drop(intent) |> CopyFixture.complete_copy(:failed)

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(dangling_dest)
      refute File.exists?(Path.join(target_dir, "missing.txt"))
    end

    test "retargets open descendants without refreshing a tree opened after move admission", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source_dir = Path.join(dir, "source")
      target_dir = Path.join(dir, "dropzone")
      active_file = Path.join(source_dir, "main.ex")
      moved_file = Path.join([target_dir, "source", "main.ex"])
      File.mkdir_p!(source_dir)
      File.mkdir_p!(target_dir)
      File.write!(active_file, "main")

      state = open_file_tree(dir, events_registry, active_file)
      intent = drop_intent(tree(state), target_dir, [source_dir])

      pending = Commands.FileTree.drop(state, intent)
      outcome = CopyFixture.take_copy(pending.effect_scheduler, :completed)
      other_tree = target_dir |> FileTree.new() |> FileTree.ensure_entries()
      other_file_tree = FileTreeState.replace_tree(ft(pending), other_tree)

      current = %{
        pending
        | workspace: SessionState.set_file_tree(pending.workspace, other_file_tree)
      }

      assert {state, %Outcome{value: {:stale, :file_tree_changed}} = stale} =
               Copy.apply(current, outcome)

      EffectScheduler.finalize(pending.effect_scheduler, stale)

      refute File.exists?(active_file)
      assert File.exists?(moved_file)
      assert Buffer.file_path(state.workspace.buffers.active) == moved_file
      assert ft(state) == other_file_tree
    end

    test "a destination opened before the move receipt keeps its own buffer and both drafts", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source = Path.join(dir, "source.txt")
      target_dir = Path.join(dir, "dropzone")
      destination = Path.join(target_dir, "source.txt")
      File.mkdir_p!(target_dir)
      File.write!(source, "disk")

      state = open_file_tree(dir, events_registry, source)
      original = state.workspace.buffers.active
      :ok = Buffer.insert_text(original, "original draft: ")
      pending = Commands.FileTree.drop(state, drop_intent(tree(state), target_dir, [source]))
      outcome = CopyFixture.take_copy(pending.effect_scheduler, :completed)
      assert File.read!(destination) == "disk"

      opened =
        start_supervised!({Buffer, file_path: destination, events_registry: events_registry},
          id: make_ref()
        )

      :ok = Buffer.insert_text(opened, "destination draft: ")
      {state, applied} = Copy.apply(pending, outcome)
      EffectScheduler.finalize(pending.effect_scheduler, applied)

      assert Buffer.file_path(original) == source
      assert Buffer.content(original) == "original draft: disk"
      assert Buffer.file_path(opened) == destination
      assert Buffer.content(opened) == "destination draft: disk"
      assert Buffer.pid_for_file(destination) == {:ok, opened}
      assert state.shell_runtime.state.notice.message =~ "Use Save As"
    end
  end

  defp ft(state), do: state.workspace.file_tree
  defp tree(state), do: state |> ft() |> FileTreeState.tree()

  defp open_file_tree(dir, events_registry, active_file \\ nil) do
    tree = dir |> FileTree.new() |> reveal_active_file(active_file) |> FileTree.ensure_entries()
    buffers = buffers_for_active_file(active_file, events_registry)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      extension_surfaces: %MingaEditor.State.ExtensionSurfaces{events_registry: events_registry},
      workspace:
        %SessionState{buffers: buffers, keymap_scope: :file_tree}
        |> SessionState.set_file_tree(FileTreeState.open(%FileTreeState{}, tree, nil))
    }
    |> CopyFixture.install_scheduler()
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
