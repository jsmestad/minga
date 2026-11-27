defmodule MingaEditor.Integration.FileTreeFramesSmokeTest do
  @moduledoc """
  Actual-path smoke for file-tree frames (#3493): keys through the Editor, the Renderer, the GUI encoder and the headless frontend's wire decoder.

  Covers what the frontend holds after opening the tree, a selection move, keyboard activation with focus returning to the editor, and a close and reopen that picks up a file created while the tree was closed.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Project.FileTree
  alias Minga.Test.FileTreeRefreshScanner
  alias Minga.Test.HeadlessPort
  alias MingaEditor.Commands.FileTree.DuplicateBackend
  alias MingaEditor.Commands.FileTree.SystemDuplicateBackend
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.Refresh
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Target

  @moduletag :tmp_dir

  defmodule GatedDuplicateBackend do
    @moduledoc false
    @behaviour DuplicateBackend

    @impl true
    @spec claim_destination(String.t(), DuplicateBackend.entry_type(), pid()) ::
            {:ok, DuplicateBackend.claim()} | {:error, term()}
    defdelegate claim_destination(path, kind, owner), to: SystemDuplicateBackend

    @impl true
    @spec copy(String.t(), DuplicateBackend.claim(), pid()) :: DuplicateBackend.copy_result()
    def copy(source, claim, owner) do
      send(owner, {:duplicate_copy_started, self()})

      receive do
        :finish_duplicate_copy -> SystemDuplicateBackend.copy(source, claim, nil)
      end
    end

    @impl true
    @spec cleanup([DuplicateBackend.owned_entry()], pid()) :: DuplicateBackend.cleanup_result()
    defdelegate cleanup(owned, owner), to: SystemDuplicateBackend
  end

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

    send_key_sync(ctx, 9)

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

  test "Editor accepts a navigation key while a directory duplicate worker is blocked", %{
    tmp_dir: dir
  } do
    peer = Path.join(dir, "a-peer")
    source = Path.join(dir, "z-source")
    duplicate = Path.join(dir, "z-source copy")
    File.mkdir!(peer)
    File.mkdir_p!(Path.join(source, "nested"))
    File.write!(Path.join(source, "nested/child.txt"), "bytes")

    ctx =
      start_editor("",
        project_root: dir,
        file_tree_duplicate_backend: {GatedDuplicateBackend, self()}
      )

    send_keys_sync(ctx, "<Space>op")

    wait_until_screen(ctx, fn ->
      match?(%{rows: [%{id: ^peer}, %{id: ^source}]}, frontend_tree(ctx))
    end)

    assert selected(frontend_tree(ctx)) == peer
    file_tree = editor_state(ctx).workspace.file_tree

    target = %Target{
      surface: :file_tree,
      intent: :duplicate,
      item_id: source,
      generation: FileTreeState.presentation_generation(file_tree)
    }

    send(ctx.editor, {:minga_input, {:gui_action, target}})
    assert_receive {:duplicate_copy_started, worker}, 2_000

    try do
      refute worker == ctx.editor
      refute File.exists?(Path.join(duplicate, "nested"))
      send_keys_sync(ctx, "j")
      assert selected(frontend_tree(ctx)) == source

      send(ctx.editor, {:minga_input, {:application_quit_request, 11}})
      wait_until_screen(ctx, fn -> minibuffer(ctx) =~ "File tree operation in progress" end)
      refute File.exists?(Path.join(duplicate, "nested"))
    after
      send(worker, :finish_duplicate_copy)
    end

    wait_until_screen(ctx, fn -> minibuffer(ctx) =~ "Duplicated z-source to z-source copy" end)
    assert File.read!(Path.join(duplicate, "nested/child.txt")) == "bytes"
    assert selected(frontend_tree(ctx)) == source
  end

  test "folder deletion shows a confirmation and cancel leaves the subtree intact", %{
    tmp_dir: dir
  } do
    nested = Path.join(dir, "nested")
    path = Path.join(nested, "deeper/file.txt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "keep")
    ctx = start_editor("", project_root: dir)

    send_keys_sync(ctx, "<Space>op")
    wait_until_screen(ctx, fn -> match?(%{rows: [%{id: ^nested}]}, frontend_tree(ctx)) end)
    send_keys_sync(ctx, "d")
    assert minibuffer(ctx) =~ "Delete 'nested/' and all its contents?"

    send_keys_sync(ctx, "n")
    refute minibuffer(ctx) =~ "Delete 'nested/'"
    assert File.read!(path) == "keep"
  end

  test "trash can wait while the tree accepts input, and permanent deletion needs a new yes", %{
    tmp_dir: dir
  } do
    {ctx, nested, worker} = start_blocked_trash(dir)
    peer = Path.join(dir, "peer.txt")

    send_keys_sync(ctx, "R-moved<CR>")
    assert minibuffer(ctx) =~ "File tree operation in progress"
    assert File.dir?(nested)
    refute File.exists?(nested <> "-moved")
    send_keys_sync(ctx, "<Esc>")

    send_keys_sync(ctx, "j")
    assert selected(frontend_tree(ctx)) == peer
    assert File.read!(Path.join(nested, "child.txt")) == "keep until confirmed"

    send(worker, :finish_trash)
    wait_until_screen(ctx, fn -> minibuffer(ctx) =~ "Permanently delete 'nested'?" end)
    assert File.dir?(nested)

    send_keys_sync(ctx, "y")

    wait_until_screen(ctx, fn ->
      match?(%{rows: [%{id: ^peer}]}, frontend_tree(ctx))
    end)

    refute File.exists?(nested)
  end

  test "the initial confirmation rejects an entry replaced after the prompt", %{tmp_dir: dir} do
    {ctx, nested} = prepare_trash(dir)
    send_keys_sync(ctx, "d")
    assert minibuffer(ctx) =~ "Delete 'nested/'"

    File.rename!(nested, Path.join(dir, "original"))
    File.mkdir!(nested)
    send_keys_sync(ctx, "y")

    wait_until_screen(ctx, fn -> minibuffer(ctx) =~ "the entry changed since confirmation" end)
    refute_received {:trash_started, _, ^nested}
    assert File.dir?(nested)
  end

  test "permanent confirmation does not delete a replacement at the original path", %{
    tmp_dir: dir
  } do
    {ctx, nested, worker} = start_blocked_trash(dir)
    send(worker, :finish_trash)
    wait_until_screen(ctx, fn -> minibuffer(ctx) =~ "Permanently delete 'nested'?" end)

    File.rename!(nested, Path.join(dir, "original"))
    File.mkdir!(nested)
    replacement = Path.join(nested, "new.txt")
    File.write!(replacement, "replacement")
    send_keys_sync(ctx, "y")

    wait_until_screen(ctx, fn -> minibuffer(ctx) =~ "the entry changed since confirmation" end)
    assert File.read!(replacement) == "replacement"
  end

  test "trash failure does not interrupt editing after leaving the file tree", %{tmp_dir: dir} do
    {ctx, nested, worker} = start_blocked_trash(dir)
    send_keys_sync(ctx, "<Space>op")
    send_keys_sync(ctx, "i")
    send(worker, :finish_trash)
    wait_until_screen(ctx, fn -> minibuffer(ctx) =~ "No permanent delete was attempted" end)

    assert editor_mode(ctx) == :insert
    assert File.dir?(nested)
  end

  test "trash failure does not take keyboard focus from Find", %{tmp_dir: dir} do
    {ctx, nested, worker} = start_blocked_trash(dir)
    send_gui_action(ctx, {:search_focus, false})
    assert MingaEditor.FocusOwner.derive(editor_state(ctx)).surface == :search

    send(worker, :finish_trash)
    wait_until_screen(ctx, fn -> minibuffer(ctx) =~ "No permanent delete was attempted" end)
    assert MingaEditor.FocusOwner.derive(editor_state(ctx)).surface == :search
    assert File.dir?(nested)
  end

  test "creation waits for a last empty directory to load and displays its naming field", %{
    tmp_dir: dir
  } do
    nested = Path.join(dir, "nested")
    File.mkdir!(nested)
    preceding = Path.join(dir, "first")
    File.mkdir!(preceding)
    ctx = start_editor("", project_root: dir)
    send_keys_sync(ctx, "<Space>op")

    wait_until_screen(ctx, fn ->
      match?(%{rows: [%{id: ^preceding}, %{id: ^nested}]}, frontend_tree(ctx))
    end)

    send_keys_sync(ctx, "j")
    assert selected(frontend_tree(ctx)) == nested

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

    wait_until_screen(ctx, fn ->
      match?(%{rows: [_, %{id: ^nested}, %{name: "", depth: 1}]}, frontend_tree(ctx))
    end)

    %{rows: [_, _, %{id: edit_id}]} = frontend_tree(ctx)
    send_keys_sync(ctx, "created")
    File.rmdir!(preceding)
    arriving = Path.join(nested, "arriving.txt")
    File.write!(arriving, "")
    :sys.replace_state(ctx.editor, &Freshness.request_refresh(&1, 0))

    wait_until_screen(ctx, fn ->
      match?(
        %{rows: [%{id: ^nested}, %{id: ^edit_id, name: "created", depth: 1}, %{id: ^arriving}]},
        frontend_tree(ctx)
      )
    end)

    send_keys_sync(ctx, ".txt<CR>")
    assert File.regular?(Path.join(nested, "created.txt"))
    refute File.exists?(Path.join(dir, "created.txt"))
  end

  test "refresh cancels an inline name when its destination disappears", %{tmp_dir: dir} do
    nested = Path.join(dir, "nested")
    File.mkdir!(nested)
    ctx = start_editor("", project_root: dir)
    send_keys_sync(ctx, "<Space>op")
    wait_until_screen(ctx, fn -> match?(%{rows: [%{id: ^nested}]}, frontend_tree(ctx)) end)
    send_keys_sync(ctx, "a")
    wait_until_screen(ctx, fn -> match?(%{rows: [_, %{name: ""}]}, frontend_tree(ctx)) end)
    send_keys_sync(ctx, "new.txt")

    File.rmdir!(nested)
    :sys.replace_state(ctx.editor, &Freshness.request_refresh(&1, 0))
    wait_until_screen(ctx, fn -> match?(%{rows: []}, frontend_tree(ctx)) end)

    send_keys_sync(ctx, "<CR>")
    refute File.exists?(nested)
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

  defp start_blocked_trash(dir) do
    {ctx, nested} = prepare_trash(dir)
    send_keys_sync(ctx, "dy")
    assert_receive {:trash_started, worker, ^nested}, 1_000
    {ctx, nested, worker}
  end

  defp prepare_trash(dir) do
    nested = Path.join(dir, "nested")
    peer = Path.join(dir, "peer.txt")
    File.mkdir!(nested)
    File.write!(Path.join(nested, "child.txt"), "keep until confirmed")
    File.write!(peer, "")
    ctx = start_editor("body", file_path: Path.join(dir, ".hidden.txt"), project_root: dir)
    scheduler = editor_state(ctx).effect_scheduler
    test = self()

    :sys.replace_state(scheduler, fn state ->
      :ok = Minga.Platform.Stub.set_trash_result({:wait, test, {:error, "native trash failed"}})
      state
    end)

    send_keys_sync(ctx, "<Space>op")

    wait_until_screen(ctx, fn ->
      match?(%{rows: [%{id: ^nested, selected?: true}, %{id: ^peer}]}, frontend_tree(ctx))
    end)

    {ctx, nested}
  end

  defp frontend_tree(%{port: port}), do: HeadlessPort.file_tree(port)

  defp selected(tree) do
    [row] = Enum.filter(tree.rows, & &1.selected?)
    row.id
  end
end
