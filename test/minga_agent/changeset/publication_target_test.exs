defmodule MingaAgent.Changeset.PublicationTargetTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Persistence.SystemFileSystem
  alias MingaAgent.Changeset.PublicationTarget

  @moduletag :tmp_dir
  @publication {SystemFileSystem, []}

  setup %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    outside = Path.join(dir, "outside")
    File.mkdir_p!(Path.join(project, "sub"))
    File.mkdir_p!(outside)
    File.write!(Path.join(project, "sub/file.txt"), "inside")
    File.write!(Path.join(outside, "x"), "outside")
    {:ok, real_project} = Minga.Project.Root.canonical_path(project)
    %{project: project, real_project: real_project, outside: outside, dir: dir}
  end

  test "refuses a relative link whose .. components leave the project", %{project: project} do
    File.ln_s!("../../outside", Path.join(project, "sub/a"))

    assert {:error, :outside_project_root} =
             PublicationTarget.write_path(project, "sub/a/x", @publication)

    assert {:error, :outside_project_root} =
             PublicationTarget.remove_path(project, "sub/a/x", @publication)
  end

  test "reports a symlink loop as :eloop", %{project: project} do
    File.ln_s!("b", Path.join(project, "a"))
    File.ln_s!("a", Path.join(project, "b"))

    assert {:error, :eloop} = PublicationTarget.write_path(project, "a", @publication)
    assert {:error, :eloop} = PublicationTarget.remove_path(project, "a", @publication)
  end

  test "does not treat a sibling sharing the root's name prefix as inside", %{
    project: project,
    dir: dir
  } do
    sibling = project <> "2"
    File.mkdir_p!(sibling)
    File.write!(Path.join(sibling, "x"), "sibling")
    File.ln_s!(Path.join(sibling, "x"), Path.join(project, "prefix"))
    File.ln_s!("../project2", Path.join(project, "prefix_dir"))

    assert {:error, :outside_project_root} =
             PublicationTarget.write_path(project, "prefix", @publication)

    assert {:error, :outside_project_root} =
             PublicationTarget.write_path(project, "prefix_dir/x", @publication)

    assert File.read!(Path.join(dir, "project2/x")) == "sibling"
  end

  test "resolves inside a project root that is itself a symlink", %{
    project: project,
    real_project: real_project,
    dir: dir
  } do
    root_link = Path.join(dir, "root_link")
    File.ln_s!(project, root_link)
    File.ln_s!(Path.join(root_link, "sub"), Path.join(project, "via_root_link"))

    assert {:ok, target} = PublicationTarget.write_path(root_link, "sub/file.txt", @publication)
    assert target == Path.join(real_project, "sub/file.txt")

    assert {:ok, ^target} =
             PublicationTarget.write_path(root_link, "via_root_link/file.txt", @publication)

    assert {:ok, entry} = PublicationTarget.remove_path(root_link, "sub/file.txt", @publication)
    assert entry == target
  end

  test "refuses new nested directories under a symlinked directory outside the project", %{
    project: project,
    outside: outside
  } do
    File.ln_s!(outside, Path.join(project, "out"))

    assert {:error, :outside_project_root} =
             PublicationTarget.write_path(project, "out/new/deeper/file.txt", @publication)

    refute File.exists?(Path.join(outside, "new"))
  end

  test "allows new nested directories inside the project", %{
    project: project,
    real_project: real_project
  } do
    assert {:ok, target} =
             PublicationTarget.write_path(project, "sub/new/deeper/file.txt", @publication)

    assert target == Path.join(real_project, "sub/new/deeper/file.txt")
  end

  test "refuses removal paths whose final name is not an entry", %{project: project} do
    for path <- ["", ".", "..", "sub/.", "sub/.."] do
      assert {:error, :invalid_path} = PublicationTarget.remove_path(project, path, @publication),
             "expected #{inspect(path)} to be refused"
    end

    assert File.dir?(Path.join(project, "sub"))
  end

  describe "relative_path/3" do
    test "maps an absolute path to its real project-relative and real paths, even through a symlinked root",
         %{project: project, real_project: real_project, dir: dir} do
      root_link = Path.join(dir, "root_link")
      File.ln_s!(project, root_link)
      File.ln_s!("file.txt", Path.join(project, "sub/alias.txt"))

      for path <- [
            Path.join(project, "sub/file.txt"),
            Path.join(root_link, "sub/file.txt"),
            Path.join(project, "sub/alias.txt"),
            Path.join(project, "sub/../sub/file.txt")
          ] do
        real_path = Path.join(real_project, "sub/file.txt")

        assert {:ok, {"sub/file.txt", ^real_path}} =
                 PublicationTarget.relative_path(root_link, path, @publication),
               "expected #{inspect(path)} to resolve inside the project"
      end
    end

    test "refuses paths that leave the project or are not absolute", %{
      project: project,
      outside: outside
    } do
      File.ln_s!(outside, Path.join(project, "vendor"))

      for path <- [
            Path.join(outside, "x"),
            Path.join(project, "vendor/x"),
            Path.join(project, "../outside/x"),
            project
          ] do
        assert {:error, :outside_project_root} =
                 PublicationTarget.relative_path(project, path, @publication),
               "expected #{inspect(path)} to be refused"
      end

      for path <- ["sub/file.txt", "untitled:Untitled-1"] do
        assert {:error, :invalid_path} =
                 PublicationTarget.relative_path(project, path, @publication)
      end
    end
  end
end
