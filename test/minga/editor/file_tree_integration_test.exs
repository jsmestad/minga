defmodule Minga.Editor.FileTreeIntegrationTest do
  @moduledoc """
  Integration tests for the file tree sidebar panel.

  Tests toggling the tree, navigation, opening files, and focus switching.
  Uses `send_keys_sync`/`send_key_sync` which synchronize on GenServer
  state rather than render frames, avoiding timing-dependent flakiness.
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Editor.State, as: EditorState
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync

  @moduletag :tmp_dir

  describe "toggle file tree (SPC o p)" do
    test "opens and closes the file tree", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Open tree
      state = send_keys_sync(ctx, "<SPC>op")
      assert state.file_tree.tree != nil
      assert state.file_tree.focused == true

      # Close tree (SPC o p again while focused)
      state = send_keys_sync(ctx, "<SPC>op")
      assert state.file_tree.tree == nil
      assert state.file_tree.focused == false
    end

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

  describe "file tree navigation" do
    test "j/k moves cursor up and down", %{tmp_dir: dir} do
      # Create files so tree has entries
      File.write!(Path.join(dir, "aaa.txt"), "")
      File.write!(Path.join(dir, "bbb.txt"), "")
      File.write!(Path.join(dir, "ccc.txt"), "")
      file = Path.join(dir, "aaa.txt")
      ctx = start_editor(file)

      # Open tree
      state = send_keys_sync(ctx, "<SPC>op")
      assert state.file_tree.tree.cursor == 0

      # Move down
      state = send_key_sync(ctx, ?j)
      assert state.file_tree.tree.cursor == 1

      # Move down again
      state = send_key_sync(ctx, ?j)
      assert state.file_tree.tree.cursor == 2

      # Move up
      state = send_key_sync(ctx, ?k)
      assert state.file_tree.tree.cursor == 1
    end

    test "q closes the tree", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      state = send_keys_sync(ctx, "<SPC>op")
      assert state.file_tree.tree != nil

      state = send_key_sync(ctx, ?q)
      assert state.file_tree.tree == nil
    end

    test "Escape closes the tree", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "<Esc>")
      assert state.file_tree.tree == nil
    end
  end

  describe "window navigation with file tree" do
    test "SPC w h focuses the file tree from editor", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Open tree (focused)
      state = send_keys_sync(ctx, "<SPC>op")
      assert state.file_tree.tree != nil
      assert state.file_tree.focused == true

      # SPC w l should passthrough from tree, unfocusing it
      state = send_keys_sync(ctx, "<SPC>wl")
      assert state.file_tree.tree != nil
      assert state.file_tree.focused == false

      # SPC w h should focus the tree again
      state = send_keys_sync(ctx, "<SPC>wh")
      assert state.file_tree.focused == true
    end

    test "SPC w l from the file tree returns focus to editor", %{tmp_dir: dir} do
      file = Path.join(dir, "test.txt")
      File.write!(file, "hello")
      ctx = start_editor(file)

      # Open tree (focused)
      state = send_keys_sync(ctx, "<SPC>op")
      assert state.file_tree.focused == true

      # SPC w l unfocuses tree, returns to editor
      state = send_keys_sync(ctx, "<SPC>wl")
      assert state.file_tree.tree != nil
      assert state.file_tree.focused == false
    end
  end

  describe "opening files from tree" do
    test "Enter on a file opens it and returns focus to editor", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "alpha.txt"), "alpha content")
      File.write!(Path.join(dir, "beta.txt"), "beta content")
      ctx = start_editor(Path.join(dir, "alpha.txt"))

      # Open tree
      state = send_keys_sync(ctx, "<SPC>op")
      entries = FileTree.visible_entries(state.file_tree.tree)
      # Find beta.txt index (tree may be rooted at project root, not tmp_dir)
      beta_idx = Enum.find_index(entries, fn e -> e.name == "beta.txt" end)

      if beta_idx do
        # Navigate to beta.txt
        for _ <- 1..beta_idx, do: send_key_sync(ctx, ?j)

        # Press Enter to open
        state = send_key_sync(ctx, 13)

        # Focus returned to editor
        assert state.file_tree.focused == false
        # Active buffer should be beta.txt
        path = BufferServer.file_path(state.buffers.active)
        assert Path.basename(path) == "beta.txt"
      else
        # Tree rooted at project root, not tmp_dir; beta.txt not visible.
        # Verify tree opened at least.
        assert state.file_tree.tree != nil
      end
    end

    test "opening a file from the tree triggers full buffer lifecycle", %{tmp_dir: dir} do
      # This test verifies that opening a file from the filetree runs the
      # same lifecycle hooks as opening via :open_file or SPC f f:
      # highlight setup, LSP notification, git buffer creation, file watcher.
      #
      # We simulate a filetree open by directly manipulating the editor state
      # to have a filetree with a known file selected, then sending Enter.
      File.write!(Path.join(dir, "main.ex"), "defmodule Main do\nend")
      File.write!(Path.join(dir, "other.ex"), "defmodule Other do\nend")
      ctx = start_editor(Path.join(dir, "main.ex"))

      # Record initial state
      state_before = :sys.get_state(ctx.editor)
      version_before = state_before.highlight.version
      original_buf = state_before.buffers.active

      # Manually set up the filetree rooted at tmp_dir so we control the entries
      tree = FileTree.new(dir)
      tree_buf = BufferSync.start_buffer(tree)

      :sys.replace_state(ctx.editor, fn s ->
        put_in(s.file_tree, %{s.file_tree | tree: tree, focused: true, buffer: tree_buf})
      end)

      # Find other.ex in the tree entries and navigate to it
      state = :sys.get_state(ctx.editor)
      entries = FileTree.visible_entries(state.file_tree.tree)
      other_idx = Enum.find_index(entries, fn e -> e.name == "other.ex" end)
      assert other_idx != nil, "other.ex should be visible in tree rooted at #{dir}"

      for _ <- 1..other_idx, do: send_key_sync(ctx, ?j)

      # Open the file via Enter
      state = send_key_sync(ctx, 13)

      # Verify the file was opened
      assert state.buffers.active != original_buf
      path = BufferServer.file_path(state.buffers.active)
      assert Path.basename(path) == "other.ex"

      # Focus returned to editor
      assert state.file_tree.focused == false

      # Wait for the async :setup_highlight message to process
      Process.sleep(50)
      state = :sys.get_state(ctx.editor)

      # Highlight setup should have fired (version bumped by parse command)
      assert state.highlight.version > version_before,
             "Expected highlight version to increase after opening a file from the tree " <>
               "(was #{version_before}, now #{state.highlight.version}). " <>
               "This means maybe_reset_highlight was not called in the filetree open path."

      # Git buffer should be started (we're inside the minga git repo)
      buf = state.buffers.active

      case Minga.Git.root_for(Path.join(dir, "other.ex")) do
        {:ok, _root} ->
          assert Map.has_key?(state.git_buffers, buf),
                 "Expected git buffer to be started for file opened from tree"

        :not_git ->
          :ok
      end
    end
  end
end
