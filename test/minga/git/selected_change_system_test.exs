defmodule Minga.Git.SelectedChangeSystemTest do
  # Serialized like the other real Git CLI tests.
  use ExUnit.Case, async: false

  alias Minga.Git
  alias Minga.Git.Change
  alias Minga.Git.System, as: GitSystem

  @moduletag :heavy
  @moduletag :tmp_dir
  @moduletag timeout: 20_000

  @git_env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "test@test.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "test@test.com"}
  ]

  setup %{tmp_dir: root} do
    git!(root, ["init", "-q"])
    :ok
  end

  test "stages only the selected nearby change on top of a shifted index", %{tmp_dir: root} do
    path = "file.txt"
    base = "first\nseparator 1\nsecond\nseparator 2\nthird\nlast\n"
    commit!(root, %{path => base, "other.txt" => "original\n"})

    write!(
      root,
      path,
      "STAGED FIRST\nstaged extra\nseparator 1\nsecond\nseparator 2\nthird\nlast\n"
    )

    write!(root, "other.txt", "unrelated staged text\n")
    git!(root, ["add", "--", path, "other.txt"])

    revised = "first\nseparator 1\nSELECTED SECOND\nseparator 2\nUNSELECTED THIRD\nlast\n"
    write!(root, path, revised)
    [selected, _other] = changes(base, revised)

    assert :ok = GitSystem.stage_change(root, path, base, revised, selected)

    assert {:ok,
            "STAGED FIRST\nstaged extra\nseparator 1\nSELECTED SECOND\nseparator 2\nthird\nlast\n"} =
             GitSystem.show_staged(root, path)

    assert {:ok, "unrelated staged text\n"} = GitSystem.show_staged(root, "other.txt")
    assert {:ok, ^base} = GitSystem.show_head(root, path)
    assert File.read!(Path.join(root, path)) == revised
  end

  test "rejects a same-line index conflict instead of relocating to repeated text", %{
    tmp_dir: root
  } do
    path = "repeated.txt"
    base = "first\nrepeat\nseparator\nrepeat\nlast\n"
    indexed = "first\nALREADY STAGED\nseparator\nrepeat\nlast\n"
    revised = "first\nSELECTED\nseparator\nrepeat\nlast\n"
    commit!(root, %{path => base})
    write!(root, path, indexed)
    git!(root, ["add", "--", path])
    write!(root, path, revised)
    [selected] = changes(base, revised)

    assert {:error, reason} = GitSystem.stage_change(root, path, base, revised, selected)
    assert reason =~ "index changed"
    assert {:ok, ^indexed} = GitSystem.show_staged(root, path)
    assert File.read!(Path.join(root, path)) == revised
  end

  test "rejects a patch if the index changed after its exact preimage was read", %{tmp_dir: root} do
    path = "file.txt"
    base = "original\nlast\n"
    indexed = base <> "concurrent addition\n"
    commit!(root, %{path => base})

    patch =
      path
      |> Change.patch(base, "selected\nlast\n", "100644")
      |> IO.iodata_to_binary()

    write!(root, path, indexed)
    git!(root, ["add", "--", path])
    assert {:error, _reason} = GitSystem.stage_patch(root, patch)
    assert {:ok, ^indexed} = GitSystem.show_staged(root, path)
    assert File.read!(Path.join(root, path)) == indexed
  end

  test "stages EOF newline changes without staging nearby text", %{tmp_dir: root} do
    add_path = "add-newline.txt"
    remove_path = "remove-newline.txt"
    base = "first\nlast"
    commit!(root, %{add_path => base, remove_path => base <> "\n"})

    for {path, before, revised, expected} <- [
          {add_path, base, "unselected first\nlast\n", base <> "\n"},
          {remove_path, base <> "\n", "unselected first\nlast", base}
        ] do
      write!(root, path, revised)
      [_other, selected] = changes(before, revised)

      assert :ok = GitSystem.stage_change(root, path, before, revised, selected)
      assert {:ok, ^expected} = GitSystem.show_staged(root, path)
      assert File.read!(Path.join(root, path)) == revised
    end
  end

  test "stages a literal Git path with quotes, backslashes, tabs and newlines", %{tmp_dir: root} do
    path = ":(glob) quote\"\\雪\tname\n.txt"
    base = "old\n"
    revised = "new\n"
    commit!(root, %{path => base})
    write!(root, path, revised)
    [selected] = changes(base, revised)

    assert :ok = GitSystem.stage_change(root, path, base, revised, selected)
    assert {:ok, ^revised} = GitSystem.show_staged(root, path)
    assert {:ok, ^base} = GitSystem.show_head(root, path)
    assert File.read!(Path.join(root, path)) == revised
  end

  test "stages additions to either a present empty blob or an untracked path", %{tmp_dir: root} do
    tracked = "tracked.txt"
    untracked = "untracked.txt"
    revised = "new contents\n"
    commit!(root, %{tracked => ""})

    for {path, expected} <- [{tracked, ""}, {untracked, nil}] do
      write!(root, path, revised)
      assert {:ok, ^expected} = GitSystem.index_blob(root, path)
      [selected] = changes(expected, revised)

      assert :ok = GitSystem.stage_change(root, path, expected, revised, selected)
      assert {:ok, ^revised} = GitSystem.index_blob(root, path)
    end
  end

  test "rejects a formerly present empty preimage but can restage after a staged deletion", %{
    tmp_dir: root
  } do
    path = "file.txt"
    revised = "recreated contents\n"
    commit!(root, %{path => ""})
    assert {:ok, stale_base = ""} = GitSystem.index_blob(root, path)
    git!(root, ["rm", "--cached", "--", path])
    write!(root, path, revised)

    [stale_change] = changes(stale_base, revised)

    assert {:error, reason} =
             GitSystem.stage_change(root, path, stale_base, revised, stale_change)

    assert reason =~ "index changed"
    assert {:ok, fresh_base = nil} = GitSystem.index_blob(root, path)

    [fresh_change] = changes(fresh_base, revised)
    assert :ok = GitSystem.stage_change(root, path, fresh_base, revised, fresh_change)
    assert {:ok, ^revised} = GitSystem.index_blob(root, path)
    assert File.read!(Path.join(root, path)) == revised
  end

  test "rejects a missing preimage when the path has since been staged as empty", %{tmp_dir: root} do
    path = "file.txt"
    revised = "new contents\n"
    assert {:ok, nil} = GitSystem.index_blob(root, path)
    [selected] = changes(nil, revised)

    write!(root, path, "")
    git!(root, ["add", "--", path])
    write!(root, path, revised)

    assert {:error, reason} = GitSystem.stage_change(root, path, nil, revised, selected)
    assert reason =~ "index changed"
    assert {:ok, ""} = GitSystem.index_blob(root, path)
  end

  test "reports an unmerged index entry as an error, not a missing blob", %{tmp_dir: root} do
    path = "conflicted.txt"
    commit!(root, %{path => "common\n"})
    git!(root, ["branch", "theirs"])
    git!(root, ["switch", "-c", "ours"])
    commit!(root, %{path => "ours\n"})
    git!(root, ["switch", "theirs"])
    commit!(root, %{path => "theirs\n"})
    git!(root, ["switch", "ours"])
    git!(root, ["merge", "--no-edit", "theirs"], 1)

    assert {:error, reason} = GitSystem.index_blob(root, path)
    assert reason =~ "unmerged"
    [selected] = changes(nil, "resolution\n")
    assert {:error, ^reason} = GitSystem.stage_change(root, path, nil, "resolution\n", selected)
  end

  test "a staged directory replacement leaves the old exact file path absent", %{tmp_dir: root} do
    path = "config"
    child = Path.join(path, "child")
    commit!(root, %{path => "original file\n"})
    File.rm!(Path.join(root, path))
    File.mkdir!(Path.join(root, path))
    write!(root, child, "replacement child\n")
    git!(root, ["add", "-A", "--", path])

    assert {:ok, "original file\n"} = GitSystem.show_head(root, path)
    assert {:ok, nil} = GitSystem.index_blob(root, path)
    assert {:ok, "replacement child\n"} = GitSystem.index_blob(root, child)
  end

  test "reports a failed Git index read as an error", %{tmp_dir: root} do
    assert {:error, reason} = GitSystem.index_blob(Path.join(root, "missing-root"), "file.txt")
    assert reason =~ "Could not read the Git index"
  end

  test "uses the revised snapshot, not the live worktree, to choose deletion or truncation", %{
    tmp_dir: root
  } do
    delete_path = "deleted.txt"
    truncate_path = "truncated.txt"
    base = "original\n"
    commit!(root, %{delete_path => base, truncate_path => base})
    write!(root, delete_path, "recreated after comparison\n")
    File.rm!(Path.join(root, truncate_path))
    [deletion] = changes(base, nil)
    [truncation] = changes(base, "")

    assert :ok = GitSystem.stage_change(root, delete_path, base, nil, deletion)
    assert :ok = GitSystem.stage_change(root, truncate_path, base, "", truncation)
    assert {:ok, nil} = GitSystem.index_blob(root, delete_path)
    assert {:ok, ""} = GitSystem.index_blob(root, truncate_path)
    assert File.read!(Path.join(root, delete_path)) == "recreated after comparison\n"
    refute File.exists?(Path.join(root, truncate_path))
  end

  test "applies a caller-supplied patch to the index, not the worktree", %{tmp_dir: root} do
    path = "file.txt"
    commit!(root, %{path => "old\n"})

    patch = """
    --- a/file.txt
    +++ b/file.txt
    @@ -1 +1 @@
    -old
    +new
    """

    assert :ok = GitSystem.stage_patch(root, patch)
    assert {:ok, "new\n"} = GitSystem.show_staged(root, path)
    assert File.read!(Path.join(root, path)) == "old\n"
  end

  defp changes(base, revised) do
    Git.diff_lines(Change.lines(base), Change.lines(revised))
  end

  defp commit!(root, files) do
    for {path, content} <- files, do: write!(root, path, content)
    git!(root, ["add", "--", "."])
    git!(root, ["commit", "-qm", "initial"])
  end

  defp write!(root, path, content), do: File.write!(Path.join(root, path), content)

  defp git!(root, args, expected_status \\ 0) do
    {output, status} =
      System.cmd("git", ["--literal-pathspecs" | args],
        cd: root,
        env: @git_env,
        stderr_to_stdout: true
      )

    assert status == expected_status, "git #{inspect(args)} returned #{status}: #{output}"
  end
end
