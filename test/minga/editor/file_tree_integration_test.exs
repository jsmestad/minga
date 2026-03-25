defmodule Minga.Editor.FileTreeIntegrationTest do
  @moduledoc """
  Integration tests for file tree state management within the Editor.

  Covers behavior that only makes sense in the context of the Editor's
  state machine: scope restoration, viewport layout changes, window focus
  cycling, mutual exclusivity with git status, and event-driven refresh.

  Navigation (j/k), basic toggle, and Enter-to-open are tested elsewhere:
  - `test/minga/file_tree_test.exs` (pure data structure)
  - `test/minga/input/file_tree_nav_test.exs` (input handler pipeline)
  - `test/minga/integration/file_tree_test.exs` (screen-level)
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Editor.State, as: EditorState

  @moduletag :tmp_dir

  describe "scope restoration on tree close" do
    test "closing tree restores :agent scope when active window is agent chat", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Open tree
      send_keys_sync(ctx, "<SPC>op")

      # Get the editor state and inject an agent chat as the active window
      # content to simulate the real scenario.
      state = :sys.get_state(ctx.editor)
      assert state.workspace.file_tree.tree != nil
      active_id = state.workspace.windows.active
      active_window = Map.get(state.workspace.windows.map, active_id)
      agent_window = %{active_window | content: {:agent_chat, self()}}
      state = put_in(state.workspace.windows.map[active_id], agent_window)

      # Toggle the tree closed and verify scope restores to :agent
      closed_state = Minga.Editor.Commands.FileTree.toggle(state)
      assert closed_state.workspace.keymap_scope == :agent
    end

    test "closing tree restores :editor scope for regular buffer window", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      send_keys_sync(ctx, "<SPC>op")

      state = :sys.get_state(ctx.editor)
      assert state.workspace.file_tree.tree != nil
      closed_state = Minga.Editor.Commands.FileTree.toggle(state)
      assert closed_state.workspace.keymap_scope == :editor
    end
  end

  describe "tree panel layout" do
    test "tree panel reduces editor viewport width", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file, width: 80)

      # Before tree: screen_rect uses full width
      state = :sys.get_state(ctx.editor)
      {_r, c, w, _h} = EditorState.screen_rect(state)
      assert c == 0
      assert w == 80

      # Open tree
      state = send_keys_sync(ctx, "<SPC>op")
      {_r, c2, w2, _h} = EditorState.screen_rect(state)
      # Tree takes some columns; editor starts after tree + separator
      assert c2 > 0
      assert w2 < 80
      assert c2 + w2 <= 80
    end
  end

  describe "window navigation with file tree" do
    test "SPC w h focuses the file tree from editor", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Open tree (focused)
      state = send_keys_sync(ctx, "<SPC>op")
      assert state.workspace.file_tree.tree != nil
      assert state.workspace.file_tree.focused == true

      # SPC w l should passthrough from tree, unfocusing it
      state = send_keys_sync(ctx, "<SPC>wl")
      assert state.workspace.file_tree.tree != nil
      assert state.workspace.file_tree.focused == false

      # SPC w h should focus the tree again
      state = send_keys_sync(ctx, "<SPC>wh")
      assert state.workspace.file_tree.focused == true
    end

    test "SPC w l from the file tree returns focus to editor", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Open tree (focused)
      state = send_keys_sync(ctx, "<SPC>op")
      assert state.workspace.file_tree.focused == true

      # SPC w l unfocuses tree, returns to editor
      state = send_keys_sync(ctx, "<SPC>wl")
      assert state.workspace.file_tree.tree != nil
      assert state.workspace.file_tree.focused == false
    end
  end

  describe "opening a file entry from the tree" do
    test "open_or_toggle on a file entry unfocuses tree and restores editor scope", %{
      tmp_dir: dir
    } do
      # Test the pure command function directly rather than navigating through
      # the GenServer, avoiding flakiness from filesystem-dependent cursor indexing.
      File.write!(Path.join(dir, "main.ex"), "defmodule Main do\nend")
      File.write!(Path.join(dir, "other.ex"), "defmodule Other do\nend")
      ctx = start_editor(Path.join(dir, "main.ex"))

      state_before = :sys.get_state(ctx.editor)
      original_buf = state_before.workspace.buffers.active

      # Build a tree rooted at tmp_dir so we control the entries
      tree = Minga.Project.FileTree.new(dir)
      tree_buf = Minga.Project.FileTree.BufferSync.start_buffer(tree)

      # Inject the tree into editor state
      :sys.replace_state(ctx.editor, fn s ->
        s =
          put_in(s.workspace.file_tree, %{
            s.workspace.file_tree
            | tree: tree,
              focused: true,
              buffer: tree_buf
          })

        put_in(s.workspace.keymap_scope, :file_tree)
      end)

      # Find other.ex and move cursor to it
      state = :sys.get_state(ctx.editor)
      entries = Minga.Project.FileTree.visible_entries(state.workspace.file_tree.tree)
      other_idx = Enum.find_index(entries, fn e -> e.name == "other.ex" end)
      assert other_idx != nil, "other.ex should be visible in tree rooted at #{dir}"

      for _ <- 1..other_idx//1, do: send_key_sync(ctx, ?j)

      # Open the file via Enter
      state = send_key_sync(ctx, 13)

      # Verify the file was opened
      assert state.workspace.buffers.active != original_buf
      path = BufferServer.file_path(state.workspace.buffers.active)
      assert Path.basename(path) == "other.ex"

      # Focus returned to editor
      assert state.workspace.file_tree.focused == false
      assert state.workspace.keymap_scope == :editor

      # Flush async messages (highlight setup is self-sent)
      state = :sys.get_state(ctx.editor)

      # Highlight version should have bumped (parse command fired)
      assert state.workspace.highlight.version > state_before.workspace.highlight.version,
             "Expected highlight version to increase after opening a file from the tree"
    end
  end

  describe "mutual exclusivity: file tree and git status" do
    # These tests call Commands.FileTree functions directly on editor state
    # rather than dispatching keys through the GenServer. This avoids flakiness
    # from global :git_status_changed events re-populating git_status_panel
    # between key dispatch and the :sys.get_state barrier.

    test "toggle opens file tree and clears git status panel", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Get the editor state and inject git status panel
      state = :sys.get_state(ctx.editor)

      state = put_in(state.workspace.keymap_scope, :git_status)

      state =
        Minga.Editor.State.set_git_status_panel(state, %{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      # Call toggle directly (pure function, no GenServer round-trip)
      result = Minga.Editor.Commands.FileTree.toggle(state)

      assert result.workspace.file_tree.tree != nil
      assert result.shell_state.git_status_panel == nil
      assert result.workspace.keymap_scope == :file_tree
    end

    test "toggle opens tree when no git_status_panel is active", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      state = :sys.get_state(ctx.editor)
      assert state.shell_state.git_status_panel == nil

      result = Minga.Editor.Commands.FileTree.toggle(state)

      assert result.workspace.file_tree.tree != nil
      assert result.workspace.keymap_scope == :file_tree
      assert result.shell_state.git_status_panel == nil
    end

    test "closing the file tree resets tree state and restores editor scope", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Open file tree via toggle
      state = :sys.get_state(ctx.editor)
      state = Minga.Editor.Commands.FileTree.toggle(state)
      assert state.workspace.file_tree.tree != nil
      assert state.workspace.keymap_scope == :file_tree

      # Close via the public function (this is what Commands.Git calls)
      closed_state = Minga.Editor.Commands.FileTree.close(state)

      assert closed_state.workspace.file_tree.tree == nil
      assert closed_state.workspace.keymap_scope == :editor
    end

    test "round-trip: git status -> file tree -> close restores editor scope", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :editor

      # Simulate git status open
      state = put_in(state.workspace.keymap_scope, :git_status)

      state =
        Minga.Editor.State.set_git_status_panel(state, %{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      # Open file tree (clears git status)
      state = Minga.Editor.Commands.FileTree.toggle(state)
      assert state.workspace.keymap_scope == :file_tree
      assert state.shell_state.git_status_panel == nil
      assert state.workspace.file_tree.tree != nil

      # Close file tree
      state = Minga.Editor.Commands.FileTree.toggle(state)
      assert state.workspace.keymap_scope == :editor
      assert state.workspace.file_tree.tree == nil
      assert state.shell_state.git_status_panel == nil
    end
  end

  describe "file tree git status refresh on save" do
    test "Editor subscribes to :buffer_saved and refreshes file tree git status", %{tmp_dir: dir} do
      file = Path.join(dir, "save_test.ex")
      File.write!(file, "x = 1\n")
      ctx = start_editor(file)

      # Open the file tree
      state = send_keys_sync(ctx, "<SPC>op")
      assert state.workspace.file_tree.tree != nil

      # Broadcast a :buffer_saved event (simulating what lsp_after_save does)
      Minga.Events.broadcast(:buffer_saved, %Minga.Events.BufferEvent{
        buffer: state.workspace.buffers.active,
        path: file
      })

      # A synchronous call to the Editor flushes its mailbox, guaranteeing
      # the :minga_event handle_info has been processed before we inspect state.
      state = :sys.get_state(ctx.editor)

      # The tree should still be present (refresh didn't crash or nil it out)
      assert state.workspace.file_tree.tree != nil
    end
  end
end
