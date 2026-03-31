defmodule Minga.Editor.FileTreeIntegrationTest do
  @moduledoc """
  Integration tests for file tree state management within the Editor.

  Covers behavior that only makes sense in the context of the Editor's
  state machine: scope restoration, viewport layout changes, mutual
  exclusivity with git status, and event-driven refresh.

  Tests that call `Commands.FileTree` functions directly inject tree state
  into an EditorState struct rather than dispatching keys through the
  GenServer. This avoids flakiness from background events
  (`:git_status_changed`, highlight setup, file watcher) racing with
  the key dispatch round-trip.

  Navigation (j/k), basic toggle, and Enter-to-open are tested elsewhere:
  - `test/minga/project/file_tree_test.exs` (pure data structure)
  - `test/minga/input/file_tree_nav_test.exs` (input handler pipeline)
  - `test/minga/integration/file_tree_test.exs` (screen-level)
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Editor.Commands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync

  @moduletag :tmp_dir

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Builds an EditorState with a file tree injected directly, bypassing
  # GenServer key dispatch. This eliminates races with background events
  # that can fire between send_keys_sync and :sys.get_state.
  #
  # The BufferSync process is registered for on_exit cleanup so it won't
  # leak if the test crashes before toggle/close stops it.
  defp state_with_tree(ctx, dir, opts \\ []) do
    scope = Keyword.get(opts, :scope, :file_tree)
    focused = Keyword.get(opts, :focused, true)

    state = :sys.get_state(ctx.editor)
    tree = FileTree.new(dir)
    buf = BufferSync.start_buffer(tree)

    ExUnit.Callbacks.on_exit(fn ->
      if is_pid(buf) and Process.alive?(buf), do: GenServer.stop(buf, :normal)
    end)

    ft_state = FileTreeState.open(state.workspace.file_tree, tree, buf)
    ft_state = %{ft_state | focused: focused}

    state
    |> put_in([Access.key(:workspace), Access.key(:file_tree)], ft_state)
    |> put_in([Access.key(:workspace), Access.key(:keymap_scope)], scope)
  end

  describe "scope restoration on tree close" do
    test "closing tree restores :agent scope when active window is agent chat", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Inject tree directly (no GenServer dispatch)
      state = state_with_tree(ctx, dir)
      assert state.workspace.file_tree.tree != nil

      # Inject an agent chat as the active window content
      active_id = state.workspace.windows.active
      active_window = Map.get(state.workspace.windows.map, active_id)
      agent_window = %{active_window | content: {:agent_chat, self()}}
      state = put_in(state.workspace.windows.map[active_id], agent_window)

      # Pure function call: toggle the tree closed
      closed_state = Commands.FileTree.toggle(state)
      assert closed_state.workspace.keymap_scope == :agent
    end

    test "closing tree restores :editor scope for regular buffer window", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Inject tree directly
      state = state_with_tree(ctx, dir)
      assert state.workspace.file_tree.tree != nil

      # Pure function call
      closed_state = Commands.FileTree.toggle(state)
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

      # Inject tree and recompute layout (pure state, no GenServer dispatch)
      state = state_with_tree(ctx, dir)
      state = Minga.Editor.Layout.invalidate(state)
      {_r, c2, w2, _h} = EditorState.screen_rect(state)
      # Tree takes some columns; editor starts after tree + separator
      assert c2 > 0
      assert w2 < 80
      assert c2 + w2 <= 80
    end
  end

  describe "opening a file entry from the tree" do
    test "opening a file from the tree via Enter key", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "main.ex"), "defmodule Main do\nend")
      File.write!(Path.join(dir, "other.ex"), "defmodule Other do\nend")
      ctx = start_editor(Path.join(dir, "main.ex"))

      original_buf = :sys.get_state(ctx.editor).workspace.buffers.active

      # Inject a tree rooted at tmp_dir so we control entries.
      # We inject directly into the GenServer rather than using <SPC>op
      # because open/1 roots the tree at Project.root(), not tmp_dir.
      tree = FileTree.new(dir)
      tree_buf = BufferSync.start_buffer(tree)

      ExUnit.Callbacks.on_exit(fn ->
        if is_pid(tree_buf) and Process.alive?(tree_buf),
          do: GenServer.stop(tree_buf, :normal)
      end)

      :sys.replace_state(ctx.editor, fn s ->
        ft = FileTreeState.open(s.workspace.file_tree, tree, tree_buf)

        s
        |> put_in([Access.key(:workspace), Access.key(:file_tree)], ft)
        |> put_in([Access.key(:workspace), Access.key(:keymap_scope)], :file_tree)
      end)

      # Barrier: ensure replace_state is processed before sending keys
      state = :sys.get_state(ctx.editor)
      assert state.workspace.file_tree.tree != nil

      # Find other.ex by content, not by hardcoded position
      entries = FileTree.visible_entries(state.workspace.file_tree.tree)
      other_idx = Enum.find_index(entries, fn e -> e.name == "other.ex" end)
      assert other_idx != nil, "other.ex should be visible in tree rooted at #{dir}"

      # Navigate cursor to it
      for _ <- 1..other_idx, do: send_key_sync(ctx, ?j)

      # Open the file via Enter
      state = send_key_sync(ctx, 13)

      # Verify the file was opened (assert on content, not buffer identity)
      assert state.workspace.buffers.active != original_buf
      path = BufferServer.file_path(state.workspace.buffers.active)
      assert Path.basename(path) == "other.ex"

      # Focus returned to editor
      assert state.workspace.file_tree.focused == false
      assert state.workspace.keymap_scope == :editor
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

      # Get base state and inject git status panel
      state = :sys.get_state(ctx.editor)

      state = put_in(state.workspace.keymap_scope, :git_status)

      state =
        EditorState.set_git_status_panel(state, %{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      # Call toggle directly (pure function, no GenServer round-trip)
      result = Commands.FileTree.toggle(state)

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

      result = Commands.FileTree.toggle(state)

      assert result.workspace.file_tree.tree != nil
      assert result.workspace.keymap_scope == :file_tree
      assert result.shell_state.git_status_panel == nil
    end

    test "closing the file tree resets tree state and restores editor scope", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Inject tree directly instead of going through GenServer
      state = state_with_tree(ctx, dir)
      assert state.workspace.file_tree.tree != nil
      assert state.workspace.keymap_scope == :file_tree

      # Pure function call
      closed_state = Commands.FileTree.close(state)

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
        EditorState.set_git_status_panel(state, %{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      # Open file tree (clears git status)
      state = Commands.FileTree.toggle(state)
      assert state.workspace.keymap_scope == :file_tree
      assert state.shell_state.git_status_panel == nil
      assert state.workspace.file_tree.tree != nil

      # Close file tree
      state = Commands.FileTree.toggle(state)
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

      # Open the tree via key dispatch (tests the event wiring)
      state = send_keys_sync(ctx, "<SPC>op")
      assert state.workspace.file_tree.tree != nil

      # Broadcast a :buffer_saved event (simulating what lsp_after_save does)
      Minga.Events.broadcast(:buffer_saved, %Minga.Events.BufferEvent{
        buffer: state.workspace.buffers.active,
        path: file
      })

      # Synchronous call flushes the editor's mailbox, guaranteeing
      # the :minga_event handle_info has been processed before we inspect.
      state = :sys.get_state(ctx.editor)

      # The tree should still be present (refresh didn't crash or nil it out)
      assert state.workspace.file_tree.tree != nil
    end
  end
end
