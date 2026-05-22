defmodule MingaEditor.Commands.FileTreeEditingTest do
  @moduledoc """
  Command-state tests for file tree inline editing commands: new file, new folder, rename, confirm, and cancel.

  Classification: these tests call file-tree command and input-handler seams directly on constructed editor state. They verify deterministic editing mode transitions, filesystem-visible mutations, overwrite protection, and open-buffer retargeting without booting the full EditorCase input/render stack.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Events
  alias Minga.Project.FileRef
  alias Minga.Project.FileTree
  alias MingaEditor.Commands
  alias MingaEditor.Input.FileTreeHandler
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState

  @backspace 127

  @moduletag :tmp_dir

  setup context do
    events_registry = private_events_registry(context)
    start_supervised!({Events, name: events_registry})
    {:ok, events_registry: events_registry}
  end

  describe "[command-state] new file (a)" do
    test "enters new-file editing mode", %{tmp_dir: dir, events_registry: events_registry} do
      state = make_state(dir, events_registry)

      state = Commands.FileTree.new_file(state)

      assert state.workspace.file_tree.editing != nil
      assert state.workspace.file_tree.editing.type == :new_file
      assert state.workspace.file_tree.editing.text == ""
    end

    test "creates file on disk after confirming a typed name", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      expected = Path.join(dir, "newfile.txt")
      _buffer = start_supervised!({Buffer, file_path: expected, events_registry: events_registry})

      state =
        dir
        |> make_state(events_registry)
        |> Commands.FileTree.new_file()
        |> replace_editing_text("newfile.txt")

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil

      assert File.exists?(expected), "Expected newfile.txt to exist at #{expected}"
    end
  end

  describe "[command-state] new folder (A)" do
    test "enters new-folder editing mode", %{tmp_dir: dir, events_registry: events_registry} do
      state = make_state(dir, events_registry)

      state = Commands.FileTree.new_folder(state)

      assert state.workspace.file_tree.editing != nil
      assert state.workspace.file_tree.editing.type == :new_folder
    end

    test "creates directory on disk after confirming a typed name", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      state =
        dir
        |> make_state(events_registry)
        |> Commands.FileTree.new_folder()
        |> replace_editing_text("newfolder")

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil

      expected = Path.join(dir, "newfolder")
      assert File.dir?(expected), "Expected newfolder to exist at #{expected}"
    end
  end

  describe "[command-state] rename (R)" do
    test "enters rename editing mode with current name pre-filled", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      file = Path.join(dir, "target.txt")
      File.write!(file, "content")

      state = dir |> make_state(events_registry) |> select_entry("target.txt")

      state = Commands.FileTree.rename(state)

      assert state.workspace.file_tree.editing != nil
      assert state.workspace.file_tree.editing.type == :rename
      assert state.workspace.file_tree.editing.text == "target.txt"
      assert state.workspace.file_tree.editing.original_name == "target.txt"
    end

    test "renames file on disk after changing name", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      file = Path.join(dir, "target.txt")
      File.write!(file, "content")

      state =
        dir
        |> make_state(events_registry)
        |> select_entry("target.txt")
        |> Commands.FileTree.rename()
        |> replace_editing_text("renamed.txt")

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil

      new_path = Path.join(dir, "renamed.txt")
      assert File.exists?(new_path), "Expected renamed.txt to exist"
      refute File.exists?(file), "Expected target.txt to no longer exist"
    end

    test "rename does not overwrite an existing sibling", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      file = Path.join(dir, "target.txt")
      existing = Path.join(dir, "existing.txt")
      File.write!(file, "content")
      File.write!(existing, "existing")

      state =
        dir
        |> make_state(events_registry)
        |> select_entry("target.txt")
        |> Commands.FileTree.rename()
        |> replace_editing_text("existing.txt")

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil
      assert File.read!(file) == "content"
      assert File.read!(existing) == "existing"
    end
  end

  describe "[command-state] rename retargets open buffers" do
    test "rename retargets a dirty open file buffer without writing its contents", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      file = Path.join(dir, "target.txt")
      renamed = Path.join(dir, "renamed.txt")
      File.write!(file, "content")
      buffer = start_supervised!({Buffer, file_path: file, events_registry: events_registry})
      {:ok, old_ref} = FileRef.from_path(dir, file)
      {:ok, new_ref} = FileRef.from_path(dir, renamed)

      :ok = Buffer.insert_char(buffer, "!")
      assert Buffer.dirty?(buffer)

      state =
        dir
        |> make_state(events_registry, buffer)
        |> select_entry("target.txt")
        |> Commands.FileTree.rename()
        |> replace_editing_text("renamed.txt")

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil
      assert Buffer.file_path(buffer) == renamed
      assert Buffer.dirty?(buffer)
      assert File.read!(renamed) == "content"
      refute File.exists?(file)
      assert TabBar.active(state.shell_state.tab_bar).file_ref == new_ref
      assert TabBar.get_workspace(state.shell_state.tab_bar, 0).active_file == new_ref
      assert WorkspaceModel.has_file?(TabBar.get_workspace(state.shell_state.tab_bar, 0), new_ref)
      refute WorkspaceModel.has_file?(TabBar.get_workspace(state.shell_state.tab_bar, 0), old_ref)

      assert :ok = Buffer.save(buffer)
      assert File.read!(renamed) == "!content"
    end

    test "rename retargets an inactive tab without stealing its workspace active file", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      source = Path.join(dir, "target.txt")
      renamed = Path.join(dir, "renamed.txt")
      File.write!(source, "content")

      target_buffer =
        start_supervised!({Buffer, file_path: source, events_registry: events_registry})

      active_buffer =
        start_supervised!(%{
          id: {:active_buffer, System.unique_integer([:positive])},
          start:
            {Buffer, :start_link,
             [[content: "active", buffer_name: "active-#{System.unique_integer([:positive])}"]]},
          restart: :temporary
        })

      {:ok, old_ref} = FileRef.from_path(dir, source)
      {:ok, new_ref} = FileRef.from_path(dir, renamed)
      {:ok, active_ref} = FileRef.from_path(dir, "active.txt")

      inactive_workspace = %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: target_buffer, list: [target_buffer], active_index: 0}
      }

      active_workspace = %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: active_buffer, list: [active_buffer], active_index: 0}
      }

      inactive_tab =
        Tab.new_file(1, "target.txt")
        |> Tab.set_file_ref(old_ref)
        |> Tab.set_context(SessionState.to_tab_context(inactive_workspace))

      {tab_bar, active_tab} = TabBar.add(TabBar.new(inactive_tab, dir), :file, "active.txt")

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

      state = %EditorState{
        port_manager: self(),
        events_registry: events_registry,
        workspace: %SessionState{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{active: active_buffer, list: [active_buffer], active_index: 0},
          file_tree:
            FileTreeState.open(%FileTreeState{}, FileTree.new(dir) |> FileTree.refresh(), nil)
        },
        shell_state: %ShellState{tab_bar: tab_bar},
        focus_stack: [MingaEditor.Input.Scoped, MingaEditor.Input.ModeFSM]
      }

      state =
        state
        |> select_entry("target.txt")
        |> Commands.FileTree.rename()
        |> replace_editing_text("renamed.txt")

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil
      assert Buffer.file_path(target_buffer) == renamed
      assert TabBar.active(state.shell_state.tab_bar).id == active_tab.id
      assert TabBar.get(state.shell_state.tab_bar, inactive_tab.id).file_ref == new_ref
      assert TabBar.get_workspace(state.shell_state.tab_bar, 0).active_file == active_ref
      assert WorkspaceModel.has_file?(TabBar.get_workspace(state.shell_state.tab_bar, 0), new_ref)
      refute WorkspaceModel.has_file?(TabBar.get_workspace(state.shell_state.tab_bar, 0), old_ref)
    end

    test "rename reports a dead buffer retarget as an error instead of crashing", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      file = Path.join(dir, "target.txt")
      renamed = Path.join(dir, "renamed.txt")
      File.write!(file, "content")
      buffer = one_shot_buffer(file)

      state =
        dir
        |> make_state(events_registry)
        |> EditorState.set_buffers(%Buffers{
          active: buffer,
          list: [buffer],
          active_index: 0
        })
        |> select_entry("target.txt")
        |> Commands.FileTree.rename()
        |> replace_editing_text("renamed.txt")

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil
      assert File.exists?(renamed)
      refute File.exists?(file)
    end

    test "rename leaves a dirty open buffer on the original path when destination exists", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      file = Path.join(dir, "target.txt")
      existing = Path.join(dir, "existing.txt")
      File.write!(file, "content")
      File.write!(existing, "existing")
      buffer = start_supervised!({Buffer, file_path: file, events_registry: events_registry})

      :ok = Buffer.insert_char(buffer, "!")
      assert Buffer.dirty?(buffer)

      state =
        dir
        |> make_state(events_registry, buffer)
        |> select_entry("target.txt")
        |> Commands.FileTree.rename()
        |> replace_editing_text("existing.txt")

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil
      assert Buffer.file_path(buffer) == file
      assert Buffer.dirty?(buffer)
      assert File.read!(file) == "content"
      assert File.read!(existing) == "existing"
    end
  end

  describe "[command-state] cancel editing" do
    test "Escape-equivalent command cancels without filesystem changes", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      state =
        dir
        |> make_state(events_registry)
        |> Commands.FileTree.new_file()
        |> replace_editing_text("partial")

      state = Commands.FileTree.cancel_editing(state)

      assert state.workspace.file_tree.editing == nil

      refute File.exists?(Path.join(dir, "partial")),
             "No file should be created when editing is cancelled"
    end

    test "confirm with empty text cancels", %{tmp_dir: dir, events_registry: events_registry} do
      state = dir |> make_state(events_registry) |> Commands.FileTree.new_file()

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil
    end

    test "Backspace on empty text cancels editing through the file-tree input handler", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      state = dir |> make_state(events_registry) |> Commands.FileTree.new_file()

      {:handled, state} = FileTreeHandler.handle_key(state, @backspace, 0)

      assert state.workspace.file_tree.editing == nil
    end
  end

  describe "[command-state] rename to same name cancels" do
    test "no filesystem operation when name unchanged", %{
      tmp_dir: dir,
      events_registry: events_registry
    } do
      file = Path.join(dir, "same.txt")
      File.write!(file, "content")

      state =
        dir
        |> make_state(events_registry)
        |> select_entry("same.txt")
        |> Commands.FileTree.rename()

      state = Commands.FileTree.confirm_editing(state)

      assert state.workspace.file_tree.editing == nil
      assert File.exists?(file), "File should still exist unchanged"
    end
  end

  defp make_state(dir, events_registry, active_buffer \\ nil) do
    tree = FileTree.new(dir)

    workspace = %SessionState{
      viewport: Viewport.new(24, 80),
      buffers: buffers_for_active_buffer(active_buffer),
      file_tree: FileTreeState.open(%FileTreeState{}, tree, nil),
      keymap_scope: :file_tree
    }

    {workspace, shell_state} =
      case active_buffer do
        nil ->
          {workspace, %ShellState{}}

        buffer when is_pid(buffer) ->
          file_ref = file_ref_for_buffer(dir, buffer)

          tab =
            Tab.new_file(1, Path.basename(file_ref.display_name))
            |> Tab.set_file_ref(file_ref)
            |> Tab.set_context(SessionState.to_tab_context(workspace))

          tab_bar =
            TabBar.new(tab, dir)
            |> TabBar.update_workspace(0, fn ws ->
              WorkspaceModel.set_active_file(ws, file_ref)
            end)

          {workspace, %ShellState{tab_bar: tab_bar}}
      end

    %EditorState{
      port_manager: self(),
      events_registry: events_registry,
      workspace: workspace,
      shell_state: shell_state,
      focus_stack: [MingaEditor.Input.Scoped, MingaEditor.Input.ModeFSM]
    }
  end

  defp file_ref_for_buffer(root, buffer) when is_pid(buffer) do
    case Buffer.file_path(buffer) do
      nil ->
        FileRef.from_buffer(buffer)

      path ->
        case FileRef.from_path(root, path) do
          {:ok, file_ref} -> file_ref
          {:error, :outside_project} -> FileRef.from_buffer(buffer)
        end
    end
  end

  defp one_shot_buffer(file_path) do
    spawn_link(fn ->
      receive do
        {:"$gen_call", from, :file_path} ->
          GenServer.reply(from, file_path)
      end
    end)
  end

  defp private_events_registry(%{module: module, test: test}) do
    Module.concat([module, test, Events])
  end

  defp buffers_for_active_buffer(nil), do: %Buffers{}
  defp buffers_for_active_buffer(buffer) when is_pid(buffer), do: Buffers.add(%Buffers{}, buffer)

  defp replace_editing_text(%EditorState{} = state, text) when is_binary(text) do
    ft = FileTreeState.update_editing_text(state.workspace.file_tree, text)
    EditorState.set_file_tree(state, ft)
  end

  defp select_entry(%EditorState{} = state, name) when is_binary(name) do
    tree = state.workspace.file_tree.tree
    entries = FileTree.visible_entries(tree)
    index = Enum.find_index(entries, &(&1.name == name))
    assert index != nil, "Expected #{name} to be visible in the file tree"

    replace_tree(state, FileTree.select(tree, index))
  end

  defp replace_tree(%EditorState{} = state, %FileTree{} = tree) do
    ft = FileTreeState.replace_tree(state.workspace.file_tree, tree)
    EditorState.set_file_tree(state, ft)
  end
end
