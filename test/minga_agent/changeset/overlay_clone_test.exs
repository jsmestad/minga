defmodule MingaAgent.Changeset.OverlayCloneTest do
  # Spawns the minga-clone-tree helper (erl_child_setup EPIPE race under
  # concurrency) and counts warnings in the global log, so it runs alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MingaAgent.Changeset.Overlay
  alias MingaAgent.Changeset.Overlay.NativeCloner
  alias MingaAgent.Test.Overlay.FailingCloner

  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  setup %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    package = Path.join(project, "node_modules/left-pad")
    File.mkdir_p!(package)
    File.write!(Path.join(package, "package.json"), ~s({"name": "left-pad"}))
    File.write!(Path.join(package, "index.js"), "original\n")
    File.mkdir_p!(Path.join(project, "node_modules/.bin"))
    File.ln_s!("../left-pad/index.js", Path.join(project, "node_modules/.bin/left-pad"))
    %{project: project, source: Path.join(package, "index.js")}
  end

  @tag :overlay_clone
  test "the helper clones a node_modules tree, so a shell write inside a package leaves the project file unchanged",
       %{project: project, source: source} do
    assert_helper_built()
    {:ok, overlay} = Overlay.create(project, cloner: NativeCloner)
    on_exit(fn -> Overlay.cleanup(overlay) end)

    assert {:ok, %{cloned_entries: 1, clone_fallbacks: 0}} = Overlay.materialize_project(overlay)

    cloned = Path.join(overlay.overlay_dir, "node_modules/left-pad/index.js")

    assert File.read_link!(Path.join(overlay.overlay_dir, "node_modules/.bin/left-pad")) ==
             "../left-pad/index.js"

    {_output, 0} =
      System.cmd("/bin/sh", ["-c", "printf 'patched\\n' > node_modules/left-pad/index.js"],
        cd: overlay.overlay_dir
      )

    assert File.read!(cloned) == "patched\n"
    assert File.read!(source) == "original\n"
    refute File.stat!(cloned).inode == File.stat!(source).inode
  end

  @tag :overlay_clone
  test "the helper reports an existing target as a real failure, not as unsupported", %{
    project: project,
    tmp_dir: dir
  } do
    assert_helper_built()
    target = Path.join(dir, "existing")
    File.mkdir_p!(target)

    assert {:error, {:clone_failed, 4, message}} =
             NativeCloner.clone(Path.join(project, "node_modules"), target)

    assert message =~ "EXIST"
  end

  test "a materialization that cannot clone warns once, however many trees fall back",
       %{project: project} do
    File.mkdir_p!(Path.join(project, "packages/web/node_modules/react"))
    {:ok, overlay} = Overlay.create(project)
    on_exit(fn -> Overlay.cleanup(overlay) end)

    log =
      capture_log(fn ->
        assert {:ok, %{clone_fallbacks: 2}} = Overlay.materialize_project(overlay)
      end)

    assert log |> String.split("could not be cloned") |> length() == 2
  end

  test "a materialization whose clone fails warns with the reason and links the packages",
       %{project: project} do
    {:ok, overlay} = Overlay.create(project, cloner: FailingCloner)
    on_exit(fn -> Overlay.cleanup(overlay) end)

    log =
      capture_log(fn ->
        assert {:ok, %{clone_fallbacks: 1, linked_entries: 2}} =
                 Overlay.materialize_project(overlay)
      end)

    assert log =~ "could not be cloned (:eacces)"
    assert File.lstat!(Path.join(overlay.overlay_dir, "node_modules/left-pad")).type == :symlink
  end

  # A missing helper makes every clone unsupported, which would read as a clone regression.
  defp assert_helper_built do
    helper = Path.join(:code.priv_dir(:minga), "minga-clone-tree")
    assert File.regular?(helper), "#{helper} is missing; run `mix native.build.support`"
  end
end
