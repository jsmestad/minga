defmodule MingaEditor.UI.Picker.ProjectFileCandidateTest do
  use ExUnit.Case, async: true

  alias Minga.Project.Root
  alias MingaEditor.UI.Picker.ProjectFileCandidate

  @moduletag :tmp_dir

  test "captures an authorized root with a normalized workspace-relative path", %{
    tmp_dir: tmp_dir
  } do
    {:ok, root} = Root.directory(tmp_dir)

    assert {:ok, %ProjectFileCandidate{root: ^root, path: "lib/file.ex"}} =
             ProjectFileCandidate.new(root, "lib/./file.ex")
  end

  test "construction rejects absolute and parent-traversing paths", %{tmp_dir: tmp_dir} do
    {:ok, root} = Root.directory(tmp_dir)

    assert {:error, :absolute_path} = ProjectFileCandidate.new(root, Path.join(tmp_dir, "file"))
    assert {:error, :parent_traversal} = ProjectFileCandidate.new(root, "../file")
    assert {:error, :empty_path} = ProjectFileCandidate.new(root, ".")
  end

  test "resolution rejects invalid or missing paths through the captured Root", %{
    tmp_dir: tmp_dir
  } do
    {:ok, root} = Root.directory(tmp_dir)

    absolute = %ProjectFileCandidate{root: root, path: Path.join(tmp_dir, "file")}
    traversal = %ProjectFileCandidate{root: root, path: "../file"}
    missing = %ProjectFileCandidate{root: root, path: "missing.txt"}

    assert {:error, :absolute_path} = ProjectFileCandidate.resolve(absolute)
    assert {:error, :parent_traversal} = ProjectFileCandidate.resolve(traversal)
    assert {:error, :enoent} = ProjectFileCandidate.resolve(missing)
  end

  test "resolution rejects a symlink escaping the captured Root", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    outside = Path.join(tmp_dir, "outside.txt")
    File.mkdir_p!(workspace)
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(workspace, "escape.txt"))
    {:ok, root} = Root.directory(workspace)
    {:ok, candidate} = ProjectFileCandidate.new(root, "escape.txt")

    assert {:error, :outside_workspace} = ProjectFileCandidate.resolve(candidate)
  end
end
