defmodule MingaEditor.Integration.FileTreeFramesSmokeTest do
  @moduledoc """
  Actual-path smoke for file-tree frames (#3493): keys through the Editor, the Renderer, the GUI encoder and the headless frontend's wire decoder.

  Covers what the frontend holds after opening the tree, a selection move, keyboard activation with focus returning to the editor, and a close and reopen that picks up a file created while the tree was closed.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Test.HeadlessPort

  @moduletag :tmp_dir

  test "the tree opens, selects, activates, returns focus and refreshes after reopen", %{
    tmp_dir: dir
  } do
    for name <- ["alpha.txt", "beta.txt", "gamma.txt"], do: File.write!(Path.join(dir, name), "")
    [alpha, beta, gamma] = Enum.map(["alpha.txt", "beta.txt", "gamma.txt"], &Path.join(dir, &1))
    ctx = start_editor("alpha", file_path: alpha, project_root: dir)

    send_keys_sync(ctx, "<Space>op")
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

    assert Enum.map(frontend_tree(ctx).rows, & &1.id) == [alpha, beta, delta, gamma]
  end

  defp frontend_tree(%{port: port}), do: HeadlessPort.file_tree(port)

  defp selected(tree) do
    [row] = Enum.filter(tree.rows, & &1.selected?)
    row.id
  end
end
