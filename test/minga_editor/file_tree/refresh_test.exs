defmodule MingaEditor.FileTree.RefreshTest do
  @moduledoc "Tests for the async file-tree rescan Task (#2632)."
  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.Refresh

  @moduletag :tmp_dir

  test "start/4 rescans off-process and replies with the refreshed tree and token",
       %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "alpha.ex"), "")
    tree = FileTree.new(tmp_dir) |> FileTree.ensure_entries()

    # A file created after the tree snapshot must show up in the rescan result.
    File.write!(Path.join(tmp_dir, "beta.ex"), "")

    token = make_ref()
    assert :ok = Refresh.start(tree, token, Minga.Events.default_registry(), self())

    assert_receive {:file_tree_refresh_result, %FileTree{} = refreshed, ^token}, 2_000

    names = refreshed |> FileTree.visible_entries() |> Enum.map(& &1.name)
    assert "alpha.ex" in names
    assert "beta.ex" in names
  end
end
