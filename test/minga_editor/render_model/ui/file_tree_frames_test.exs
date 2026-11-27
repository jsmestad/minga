defmodule MingaEditor.RenderModel.UI.FileTreeFramesTest do
  @moduledoc """
  Frame-to-frame file-tree contract at the GUI adapter boundary (#3493).

  Each test builds one frame, changes one input the semantic model depends on, builds the next frame, and asserts what the frontend receives. An unchanged frame must send nothing; every changed input must reach the frontend on the next frame. A cache that missed an invalidation would make the second frame send nothing or stale rows, and these tests would fail.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.FileTreeEncoder
  alias Minga.Language
  alias Minga.Language.Devicon
  alias Minga.Project.FileTree
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.FileTreeBuilder
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.UI.Theme

  @moduletag :tmp_dir

  @op_full_tree Minga.Protocol.Opcodes.gui_file_tree()
  @op_selection Minga.Protocol.Opcodes.gui_file_tree_selection()

  setup %{tmp_dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    for name <- ["lib/a.ex", "lib/b.py", "Makefile", "README.md"],
        do: File.write!(Path.join(dir, name), "")

    tree = dir |> FileTree.new() |> FileTree.expand_path(lib) |> FileTree.ensure_entries()
    %{dir: Path.expand(dir), lib: Path.expand(lib), tree: tree}
  end

  test "an unchanged frame sends nothing and rebuilds an equal model", %{tree: tree} do
    ctx = context(open(tree))

    {:full_tree, first, caches} = frame(ctx, Caches.new())
    {:nothing, second, _caches} = frame(ctx, caches)

    assert second == first
  end

  test "every visible entry is resident, including while the sidebar is hidden", %{tree: tree} do
    entry_ids = Enum.map(FileTree.visible_entries(tree), &Path.expand(&1.path))

    for file_tree <- [open(tree), FileTreeState.hide(open(tree))] do
      {:full_tree, model, _caches} = frame(context(file_tree), Caches.new())

      assert Enum.map(model.rows, & &1.id) == entry_ids
      assert Enum.map(model.rows, & &1.path) == entry_ids
    end
  end

  test "an oversized tree sends an error and recovers after narrowing", %{tree: tree} do
    oversized = FileTree.put_entries(tree, List.duplicate(hd(tree.entries), 65_536))
    file_tree = open(oversized)

    {:full_tree, error, caches} = frame(context(file_tree), Caches.new())
    assert {:error, "Too many entries" <> _} = error.status
    assert error.rows == []

    hidden = FileTreeState.hide(file_tree)
    {:full_tree, hidden_model, caches} = frame(context(hidden), caches)
    assert %{status: :hidden, rows: []} = hidden_model

    narrowed = FileTreeState.replace_tree(file_tree, tree)
    {:full_tree, ready, _caches} = frame(context(narrowed), caches)
    assert %{status: :ready, rows: [_ | _]} = ready
  end

  test "file icons and colors match per-path filetype detection", %{tree: tree} do
    theme = Theme.get!(:doom_one)
    {:full_tree, model, _caches} = frame(context(open(tree)), Caches.new())

    files = Enum.reject(model.rows, & &1.flags.directory?)
    assert Enum.map(files, & &1.name) |> Enum.sort() == ["Makefile", "README.md", "a.ex", "b.py"]

    for row <- files do
      filetype = Language.detect_filetype(row.name)
      assert row.icon == Devicon.icon(filetype), row.name
      assert row.icon_color == Theme.icon_color(theme, filetype), row.name
    end
  end

  test "a selection move sends only the selection", %{tree: tree} do
    file_tree = open(tree)
    {:full_tree, before, caches} = frame(context(file_tree), Caches.new())

    moved = FileTreeState.replace_tree_metadata(file_tree, FileTree.move_down(tree))
    {:selection, after_move, _caches} = frame(context(moved), caches)

    assert after_move.rows == before.rows
    refute after_move.selected_id == before.selected_id
    assert after_move.selected_id == Enum.at(before.rows, 1).id
  end

  test "collapse and expand resend the tree without and then with the children", %{
    tree: tree,
    lib: lib
  } do
    {:ok, at_lib} = FileTree.select_path(tree, lib)
    file_tree = open(at_lib)
    {:full_tree, _model, caches} = frame(context(file_tree), Caches.new())

    collapsed = FileTree.toggle_expand(at_lib) |> FileTree.ensure_entries()
    file_tree = FileTreeState.replace_tree_metadata(file_tree, collapsed)
    {:full_tree, model, caches} = frame(context(file_tree), caches)
    refute Enum.any?(model.rows, &(&1.name == "a.ex"))
    refute Enum.find(model.rows, &(&1.id == lib)).flags.expanded?

    expanded = FileTree.toggle_expand(collapsed) |> FileTree.ensure_entries()
    file_tree = FileTreeState.replace_tree_metadata(file_tree, expanded)
    {:full_tree, model, _caches} = frame(context(file_tree), caches)
    assert Enum.any?(model.rows, &(&1.name == "a.ex"))
    assert Enum.find(model.rows, &(&1.id == lib)).flags.expanded?
  end

  test "a filesystem update resends the tree and keeps surviving row identities", %{
    tree: tree,
    lib: lib
  } do
    file_tree = open(tree)
    {:full_tree, before, caches} = frame(context(file_tree), Caches.new())

    added = Path.join(lib, "c.go")
    File.write!(added, "")
    refreshed = FileTreeState.replace_tree_metadata(file_tree, FileTree.refresh(tree))
    {:full_tree, after_update, _caches} = frame(context(refreshed), caches)

    assert Enum.find(after_update.rows, &(&1.id == added)).icon == Devicon.icon(:go)
    after_ids = MapSet.new(after_update.rows, & &1.id)
    assert Enum.all?(before.rows, &MapSet.member?(after_ids, &1.id))
  end

  test "filtering resends only the matching rows and clearing restores them", %{tree: tree} do
    file_tree = open(tree)
    {:full_tree, all, caches} = frame(context(file_tree), Caches.new())

    filtered = tree |> FileTree.set_filter("b.py") |> FileTree.ensure_entries()
    file_tree = FileTreeState.replace_tree_metadata(file_tree, filtered)
    {:full_tree, model, caches} = frame(context(file_tree), caches)
    assert Enum.map(model.rows, & &1.name) == ["b.py"]

    cleared = filtered |> FileTree.clear_filter() |> FileTree.ensure_entries()
    file_tree = FileTreeState.replace_tree_metadata(file_tree, cleared)
    {:full_tree, model, _caches} = frame(context(file_tree), caches)
    assert Enum.map(model.rows, & &1.id) == Enum.map(all.rows, & &1.id)
  end

  test "a git status change resends the tree with the new badge", %{tree: tree, lib: lib} do
    file_tree = open(tree)
    {:full_tree, _model, caches} = frame(context(file_tree), Caches.new())

    path = Path.join(lib, "a.ex")
    badged = FileTree.replace_git_status(tree, %{path => :modified, lib => :modified})
    file_tree = FileTreeState.replace_tree_metadata(file_tree, badged)
    {:full_tree, model, _caches} = frame(context(file_tree), caches)

    assert Enum.find(model.rows, &(&1.id == path)).git_status == :modified
    assert Enum.find(model.rows, &(&1.id == lib)).git_status == :modified
  end

  test "a root change resends the tree for the new root", %{tree: tree, lib: lib} do
    file_tree = open(tree)
    {:full_tree, _model, caches} = frame(context(file_tree), Caches.new())

    rerooted = tree |> FileTree.reroot(lib) |> FileTree.ensure_entries()

    {:full_tree, model, _caches} =
      frame(context(FileTreeState.replace_tree(file_tree, rerooted)), caches)

    assert model.root_path == lib
    assert Enum.map(model.rows, & &1.name) == ["a.ex", "b.py"]
  end

  test "the active row follows the active buffer", %{tree: tree, lib: lib} do
    alpha = start_supervised!({BufferProcess, file_path: Path.join(lib, "a.ex")}, id: :alpha)
    beta = start_supervised!({BufferProcess, file_path: Path.join(lib, "b.py")}, id: :beta)
    file_tree = open(tree)

    {:full_tree, model, caches} =
      frame(
        context(file_tree, buffers: %Buffers{active: alpha, list: [alpha, beta]}),
        Caches.new()
      )

    assert active_names(model) == ["a.ex"]

    {:full_tree, model, _caches} =
      frame(context(file_tree, buffers: %Buffers{active: beta, list: [alpha, beta]}), caches)

    assert active_names(model) == ["b.py"]
  end

  test "editing a buffer marks its row dirty on the next frame", %{tree: tree, lib: lib} do
    buffer = start_supervised!({BufferProcess, file_path: Path.join(lib, "a.ex")})
    ctx = context(open(tree), buffers: %Buffers{active: buffer, list: [buffer]})
    {:full_tree, model, caches} = frame(ctx, Caches.new())
    refute Enum.any?(model.rows, & &1.flags.dirty?)

    :ok = Buffer.insert_char(buffer, "x")
    {:full_tree, model, _caches} = frame(ctx, caches)

    assert model.rows |> Enum.filter(& &1.flags.dirty?) |> Enum.map(& &1.name) == ["a.ex"]
  end

  test "a theme change recolors file icons on the next frame", %{tree: tree} do
    doom = Theme.icon_color(Theme.get!(:doom_one), :python)
    astrodark = Theme.icon_color(Theme.get!(:astrodark), :python)
    refute doom == astrodark

    file_tree = open(tree)
    {:full_tree, model, caches} = frame(context(file_tree, theme: :doom_one), Caches.new())
    assert python_color(model) == doom

    {:full_tree, model, _caches} = frame(context(file_tree, theme: :astrodark), caches)
    assert python_color(model) == astrodark
  end

  test "a width change resends the tree", %{dir: dir, lib: lib, tree: tree} do
    file_tree = open(tree)
    {:full_tree, _model, caches} = frame(context(file_tree), Caches.new())

    wider =
      dir |> FileTree.new(width: 44) |> FileTree.expand_path(lib) |> FileTree.ensure_entries()

    {:full_tree, model, _caches} =
      frame(context(FileTreeState.replace_tree_metadata(file_tree, wider)), caches)

    assert model.tree_width == 44
  end

  test "moving focus away from the tree reaches the frontend", %{tree: tree} do
    file_tree = open(tree)
    {:full_tree, focused, caches} = frame(context(file_tree), Caches.new())
    assert focused.focused?

    {sent, unfocused, _caches} = frame(context(FileTreeState.unfocus(file_tree)), caches)

    refute sent == :nothing
    refute unfocused.focused?
    assert unfocused.rows == focused.rows
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec frame(Context.t(), Caches.t()) ::
          {:nothing | :full_tree | :selection, Minga.RenderModel.UI.FileTree.t(), Caches.t()}
  defp frame(ctx, caches) do
    model = FileTreeBuilder.build(ctx)
    {command, caches} = FileTreeEncoder.encode(model, caches)
    {sent(command), model, caches}
  end

  defp sent(nil), do: :nothing
  defp sent(<<@op_full_tree, _rest::binary>>), do: :full_tree
  defp sent(<<@op_selection, _rest::binary>>), do: :selection

  defp open(tree), do: FileTreeState.open(%FileTreeState{}, tree, nil)

  defp context(file_tree, opts \\ []) do
    ctx = TestHelpers.base_state(port_manager: nil) |> Context.from_editor_state()
    buffers = Keyword.get(opts, :buffers, %Buffers{})
    workspace = %{ctx.workspace | file_tree: file_tree, buffers: buffers}
    frame = %{ctx.intent.frame | theme: Theme.get!(Keyword.get(opts, :theme, :doom_one))}
    %{ctx | workspace: workspace, intent: %{ctx.intent | frame: frame, workspace: workspace}}
  end

  defp active_names(model),
    do: model.rows |> Enum.filter(& &1.flags.active?) |> Enum.map(& &1.name)

  defp python_color(model), do: Enum.find(model.rows, &(&1.name == "b.py")).icon_color
end
