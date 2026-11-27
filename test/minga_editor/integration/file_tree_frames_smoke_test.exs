defmodule MingaEditor.Integration.FileTreeFramesSmokeTest do
  @moduledoc """
  Actual-path smoke for file-tree frames (#3493): keys through the Editor, the Renderer, the GUI encoder and the headless frontend's wire decoder.

  Covers what the frontend holds after opening the tree, a selection move, keyboard activation with focus returning to the editor, and a close and reopen that picks up a file created while the tree was closed.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Project.FileTree
  alias Minga.Test.FileTreeRefreshScanner
  alias Minga.Test.HeadlessPort
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.Refresh
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Target

  @moduletag :tmp_dir

  test "the tree opens, selects, activates, returns focus and refreshes after reopen", %{
    tmp_dir: dir
  } do
    for name <- ["alpha.txt", "beta.txt", "gamma.txt"], do: File.write!(Path.join(dir, name), "")
    [alpha, beta, gamma] = Enum.map(["alpha.txt", "beta.txt", "gamma.txt"], &Path.join(dir, &1))
    ctx = start_editor("alpha", file_path: alpha, project_root: dir)

    send_keys_sync(ctx, "<Space>op")
    wait_until_screen(ctx, fn -> match?(%{rows: [_, _, _]}, frontend_tree(ctx)) end)
    tree = frontend_tree(ctx)
    assert tree.visible?
    assert tree.focused?
    assert Enum.map(tree.rows, & &1.id) == [alpha, beta, gamma]
    assert selected(tree) == alpha

    send_keys_sync(ctx, "j")
    assert selected(frontend_tree(ctx)) == beta

    state = send_keys_sync(ctx, "<CR>")
    assert Minga.Buffer.file_path(state.workspace.buffers.active) == beta
    assert state.workspace.keymap_scope == :editor
    refute frontend_tree(ctx).focused?

    send_keys_sync(ctx, "<Space>op")
    refute frontend_tree(ctx).visible?
    send_keys_sync(ctx, "<Space>op")
    assert frontend_tree(ctx).visible?
    send_keys_sync(ctx, "q")
    refute file_tree_open?(ctx)

    delta = Path.join(dir, "delta.txt")
    File.write!(delta, "")
    send_keys_sync(ctx, "<Space>op")
    wait_until_screen(ctx, fn -> match?(%{rows: [_, _, _, _]}, frontend_tree(ctx)) end)

    assert Enum.map(frontend_tree(ctx).rows, & &1.id) == [alpha, beta, delta, gamma]
  end

  test "Tab expands a directory selected in the file tree", %{tmp_dir: dir} do
    nested = Path.join(dir, "nested")
    File.mkdir!(nested)
    path = Path.join(nested, "inner.txt")
    File.write!(path, "")
    ctx = start_editor("", project_root: dir)

    send_keys_sync(ctx, "<Space>op")

    wait_until_screen(ctx, fn -> match?(%{rows: [%{id: ^nested}]}, frontend_tree(ctx)) end)

    send_keys_sync(ctx, "<Tab>")

    wait_until_screen(ctx, fn ->
      match?(%{rows: [%{id: ^nested}, %{id: ^path}]}, frontend_tree(ctx))
    end)

    assert selected(frontend_tree(ctx)) == nested
  end

  test "clicking another directory preserves the selected row after its scan", %{tmp_dir: dir} do
    nested = Path.join(dir, "nested")
    File.mkdir!(nested)
    path = Path.join(nested, "inner.txt")
    peer = Path.join(dir, "peer.txt")
    File.write!(path, "")
    File.write!(peer, "")
    ctx = start_editor("peer", file_path: peer, project_root: dir)

    send_keys_sync(ctx, "<Space>op")

    wait_until_screen(ctx, fn ->
      match?(%{rows: [%{id: ^nested}, %{id: ^peer}]}, frontend_tree(ctx))
    end)

    assert selected(frontend_tree(ctx)) == peer
    file_tree = editor_state(ctx).workspace.file_tree

    send_gui_action(ctx, %Target{
      surface: :file_tree,
      intent: :toggle,
      item_id: nested,
      generation: FileTreeState.presentation_generation(file_tree)
    })

    wait_until_screen(ctx, fn ->
      match?(%{rows: [%{id: ^nested}, %{id: ^path}, %{id: ^peer}]}, frontend_tree(ctx))
    end)

    assert selected(frontend_tree(ctx)) == peer
  end

  test "creation waits for a collapsed directory to load and targets that directory", %{
    tmp_dir: dir
  } do
    nested = Path.join(dir, "nested")
    File.mkdir!(nested)
    path = Path.join(nested, "existing.txt")
    File.write!(path, "")
    ctx = start_editor("", project_root: dir)
    send_keys_sync(ctx, "<Space>op")
    wait_until_screen(ctx, fn -> match?(%{rows: [%{id: ^nested}]}, frontend_tree(ctx)) end)

    state = editor_state(ctx)

    blocker =
      Refresh.request(FileTree.new(dir), state.extension_surfaces.events_registry,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :before_create, :wait},
        synchronize_watchers?: false
      )

    assert {:ok, _, :running} = EffectScheduler.schedule(state.effect_scheduler, blocker)
    assert_receive {:file_tree_scan_started, :before_create, worker}, 1_000

    send_keys_sync(ctx, "a")
    assert %{visible?: true, rows: []} = frontend_tree(ctx)
    refute FileTreeState.editing?(editor_state(ctx).workspace.file_tree)

    send(worker, {:release_file_tree_scan, :before_create, {:return, FileTree.new(dir)}})
    wait_until(ctx, &FileTreeState.editing?(&1.workspace.file_tree))
    send_keys_sync(ctx, "created.txt<CR>")
    assert File.regular?(Path.join(nested, "created.txt"))
    refute File.exists?(Path.join(dir, "created.txt"))
  end

  test "the tree can be hidden and shown while its initial scan is pending", %{tmp_dir: dir} do
    nested = Path.join(dir, "nested")
    File.mkdir!(nested)
    path = Path.join(nested, "selected.txt")
    File.write!(path, "")
    ctx = start_editor("selected", file_path: path, project_root: dir)
    state = editor_state(ctx)

    blocked =
      Refresh.request(FileTree.new(dir), state.extension_surfaces.events_registry,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :before_open, :wait},
        synchronize_watchers?: false
      )

    assert {:ok, _, :running} = EffectScheduler.schedule(state.effect_scheduler, blocked)
    assert_receive {:file_tree_scan_started, :before_open, worker}, 1_000

    send_keys_sync(ctx, "<Space>op")
    assert %{visible?: true, rows: []} = frontend_tree(ctx)

    file_tree = editor_state(ctx).workspace.file_tree

    send_gui_action(ctx, %Target{
      surface: :file_tree,
      intent: :new_file,
      item_id: "",
      generation: FileTreeState.presentation_generation(file_tree)
    })

    refute FileTreeState.editing?(editor_state(ctx).workspace.file_tree)

    send_keys_sync(ctx, "a")
    send_keys_sync(ctx, "j")
    assert %{visible?: true, rows: []} = frontend_tree(ctx)

    send_keys_sync(ctx, "<Space>op")
    assert %{visible?: false} = frontend_tree(ctx)
    send_keys_sync(ctx, "<Space>op")
    assert %{visible?: true, rows: []} = frontend_tree(ctx)

    :sys.replace_state(ctx.editor, &Freshness.request_refresh(&1, 0))
    send_keys_sync(ctx, "j")
    assert %{visible?: true, rows: []} = frontend_tree(ctx)

    send(worker, {:release_file_tree_scan, :before_open, {:return, FileTree.new(dir)}})

    wait_until_screen(ctx, fn ->
      match?(%{rows: [%{id: ^nested}, %{id: ^path}]}, frontend_tree(ctx))
    end)

    assert selected(frontend_tree(ctx)) == path
  end

  defp frontend_tree(%{port: port}), do: HeadlessPort.file_tree(port)

  defp selected(tree) do
    [row] = Enum.filter(tree.rows, & &1.selected?)
    row.id
  end
end
