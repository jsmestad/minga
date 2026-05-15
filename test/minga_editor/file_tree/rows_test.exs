defmodule MingaEditor.FileTree.RowsTest do
  @moduledoc "Tests semantic row construction for file-tree renderers."

  use ExUnit.Case, async: true

  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.Diagnostics, as: RowDiagnostics
  alias MingaEditor.FileTree.Rows
  alias MingaEditor.State.FileTree, as: FileTreeState

  @moduletag :tmp_dir

  describe "from_tree/2" do
    test "marks selected and focused rows", %{tmp_dir: tmp_dir} do
      tree =
        tmp_dir
        |> flat_tree()
        |> FileTree.select(1)

      rows = Rows.from_tree(tree, focused: true)

      assert Enum.at(rows, 0).selected? == false
      selected = Enum.at(rows, 1)
      assert selected.selected? == true
      assert selected.focused? == true
    end

    test "marks active, dirty, and git state independently", %{tmp_dir: tmp_dir} do
      tree = flat_tree(tmp_dir)
      file_path = Path.join(tmp_dir, "alpha.ex")

      [row | _] =
        Rows.from_tree(tree,
          active_path: file_path,
          dirty_paths: MapSet.new([file_path]),
          git_status: %{file_path => :modified}
        )

      assert row.path == file_path
      assert row.active? == true
      assert row.dirty? == true
      assert row.git_status == :modified
    end

    test "does not mark directories dirty", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      tree = FileTree.new(tmp_dir)
      dir_path = Path.join(tmp_dir, "lib")

      [row] = Rows.from_tree(tree, dirty_paths: MapSet.new([dir_path]))

      assert row.directory? == true
      assert row.dirty? == false
    end

    test "attaches diagnostic counts to file rows", %{tmp_dir: tmp_dir} do
      tree = flat_tree(tmp_dir)
      file_path = Path.join(tmp_dir, "alpha.ex")

      [row | _] = Rows.from_tree(tree, diagnostics: %{file_path => {2, 1, 0, 3}})

      assert row.diagnostics.error_count == 2
      assert row.diagnostics.warning_count == 1
      assert row.diagnostics.hint_count == 3
      assert RowDiagnostics.highest_severity(row.diagnostics) == :error
    end

    test "accepts diagnostics count maps from the diagnostics store", %{tmp_dir: tmp_dir} do
      tree = flat_tree(tmp_dir)
      file_path = Path.join(tmp_dir, "alpha.ex")

      [row | _] =
        Rows.from_tree(tree,
          diagnostics: %{file_path => %{error: 1, warning: 2, info: 3, hint: 4}}
        )

      assert row.diagnostics.error_count == 1
      assert row.diagnostics.warning_count == 2
      assert row.diagnostics.info_count == 3
      assert row.diagnostics.hint_count == 4
    end

    test "reads diagnostics from the diagnostics store by default", %{tmp_dir: tmp_dir} do
      diagnostics_server =
        start_supervised!({Diagnostics, name: :"row_diag_#{System.unique_integer()}"})

      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      file_path = Path.join([tmp_dir, "lib", "a.ex"])
      File.write!(file_path, "")

      Diagnostics.publish(
        diagnostics_server,
        :test,
        Minga.LSP.SyncServer.path_to_uri(file_path),
        [diagnostic(:error), diagnostic(:hint)]
      )

      rows = tmp_dir |> FileTree.new() |> Rows.from_tree(diagnostics_server: diagnostics_server)
      lib = Enum.find(rows, &(&1.name == "lib"))

      assert lib.diagnostics.error_count == 1
      assert lib.diagnostics.hint_count == 1
      assert RowDiagnostics.highest_severity(lib.diagnostics) == :error
    end

    test "propagates diagnostic status to ancestor directories", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join([tmp_dir, "lib", "minga"]))
      file_path = Path.join([tmp_dir, "lib", "minga", "editor.ex"])
      File.write!(file_path, "")

      tree = FileTree.new(tmp_dir)
      rows = Rows.from_tree(tree, diagnostics: %{file_path => {0, 1, 0, 0}})
      lib = Enum.find(rows, &(&1.name == "lib"))

      assert lib.directory? == true
      assert lib.diagnostics.warning_count == 1
      assert RowDiagnostics.highest_severity(lib.diagnostics) == :warning
    end

    test "merges descendant diagnostic counts on directory rows", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      first_path = Path.join([tmp_dir, "lib", "a.ex"])
      second_path = Path.join([tmp_dir, "lib", "b.ex"])
      File.write!(first_path, "")
      File.write!(second_path, "")

      tree = FileTree.new(tmp_dir)

      rows =
        Rows.from_tree(tree,
          diagnostics: %{first_path => {1, 0, 0, 0}, second_path => {0, 2, 0, 0}}
        )

      lib = Enum.find(rows, &(&1.name == "lib"))

      assert lib.diagnostics.error_count == 1
      assert lib.diagnostics.warning_count == 2
      assert RowDiagnostics.highest_severity(lib.diagnostics) == :error
    end

    test "ignores diagnostics outside sibling paths with the same prefix", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "inside.ex"]), "")
      outside_path = Path.join([tmp_dir <> "_sibling", "lib", "outside.ex"])

      rows =
        tmp_dir
        |> FileTree.new()
        |> Rows.from_tree(diagnostics: %{outside_path => {1, 0, 0, 0}})

      lib = Enum.find(rows, &(&1.name == "lib"))

      assert RowDiagnostics.total_count(lib.diagnostics) == 0
    end

    test "attaches inline editing metadata only to the edited index", %{tmp_dir: tmp_dir} do
      tree = flat_tree(tmp_dir)
      editing = %{index: 1, text: "renamed.ex", type: :rename, original_name: "beta.ex"}

      rows = Rows.from_tree(tree, editing: editing)

      assert Enum.at(rows, 0).editing == nil
      assert Enum.at(rows, 1).editing == editing
    end

    test "preserves nested depth, guides, and last-child metadata", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join([tmp_dir, "lib", "minga"]))
      File.write!(Path.join([tmp_dir, "lib", "minga", "editor.ex"]), "")

      tree =
        FileTree.new(tmp_dir)
        |> FileTree.expand_path(Path.join(tmp_dir, "lib"))
        |> FileTree.expand_path(Path.join([tmp_dir, "lib", "minga"]))

      row =
        tree
        |> Rows.from_tree()
        |> Enum.find(&(&1.name == "editor.ex"))

      assert row.depth == 2
      assert row.guides == [false, false]
      assert row.last_child? == true
      assert row.path == Path.join([tmp_dir, "lib", "minga", "editor.ex"])
    end

    test "returns no rows for an empty visible tree", %{tmp_dir: tmp_dir} do
      assert Rows.from_tree(FileTree.new(tmp_dir)) == []
    end
  end

  describe "FileTreeState.status/1" do
    test "distinguishes hidden, empty, ready, loading, and error states", %{tmp_dir: tmp_dir} do
      assert FileTreeState.status(%FileTreeState{}) == :hidden

      empty_tree = FileTree.new(tmp_dir)
      assert FileTreeState.status(FileTreeState.open(%FileTreeState{}, empty_tree, nil)) == :empty

      ready_tree = flat_tree(tmp_dir)
      assert FileTreeState.status(FileTreeState.open(%FileTreeState{}, ready_tree, nil)) == :ready

      loading = FileTreeState.loading(%FileTreeState{project_root: tmp_dir})
      assert FileTreeState.status(loading) == :loading

      missing_tree = FileTree.new(Path.join(tmp_dir, "missing"))

      assert {:error, reason} =
               FileTreeState.status(FileTreeState.open(%FileTreeState{}, missing_tree, nil))

      assert reason != ""
    end

    test "replace_tree clears stale loading or error state", %{tmp_dir: tmp_dir} do
      ready_tree = flat_tree(tmp_dir)

      loading =
        %FileTreeState{tree: ready_tree}
        |> FileTreeState.loading()
        |> FileTreeState.replace_tree(ready_tree)

      assert FileTreeState.status(loading) == :ready

      errored =
        %FileTreeState{tree: ready_tree}
        |> FileTreeState.error(:eacces)
        |> FileTreeState.replace_tree(ready_tree)

      assert FileTreeState.status(errored) == :ready
    end

    test "width preserves the last sidebar width for state-only payloads", %{tmp_dir: tmp_dir} do
      tree = FileTree.new(tmp_dir, width: 42)
      file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)

      assert FileTreeState.width(file_tree) == 42
      assert file_tree |> FileTreeState.close() |> FileTreeState.width() == 42
    end
  end

  defp flat_tree(tmp_dir) do
    File.write!(Path.join(tmp_dir, "alpha.ex"), "")
    File.write!(Path.join(tmp_dir, "beta.ex"), "")
    FileTree.new(tmp_dir)
  end

  defp diagnostic(severity) do
    %Diagnostic{
      range: %{start_line: 0, start_col: 0, end_line: 0, end_col: 1},
      severity: severity,
      message: "diagnostic",
      source: "test",
      code: nil
    }
  end
end
