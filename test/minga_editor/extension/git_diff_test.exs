defmodule MingaEditor.Extension.GitDiffTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.GitDiff
  alias MingaEditor.Extension.GitDiff.Hunk
  alias MingaEditor.Extension.GitDiff.Origin
  alias MingaEditor.Extension.GitDiff.Target
  alias MingaEditor.RenderPipeline.TestHelpers

  @tag :tmp_dir
  test "layout and navigation select the exact rendered hunk", %{tmp_dir: root} do
    state = TestHelpers.gui_state()
    origin = %Origin{git_root: root, rel_path: "file.txt", section: :unstaged}
    base = "old first\ncontext\nold second\n"
    current = "new first\ncontext\nnew second\n"

    assert {:ok, state} = GitDiff.open(state, origin, {base, current})
    diff = EditorAPI.active_buffer(state)
    assert Buffer.read_only?(diff)
    assert Buffer.buffer_name(diff) == "file.txt [diff:unstaged]"

    assert {:ok,
            %Target{origin: ^origin, layout: :unified, contents: {^base, ^current}, hunk: first}} =
             GitDiff.target(state, diff)

    assert %Hunk{
             index: 1,
             total: 2,
             change: %{start_line: 0, count: 1, old_start: 0, old_lines: ["old first"]}
           } = first

    assert :ok = Buffer.move_to(diff, {2, 0})
    assert {:ok, %Target{hunk: nil}} = GitDiff.target(state, diff)
    assert {:ok, state} = GitDiff.navigate(state, diff, :next)

    assert {:ok,
            %Target{
              hunk: %Hunk{index: 2, change: %{start_line: 2, old_lines: ["old second"]}} = second
            }} = GitDiff.target(state, diff)

    assert {:ok, state} = GitDiff.set_layout(state, diff, :side_by_side)
    assert EditorAPI.active_buffer(state) == diff
    assert Buffer.content(diff) =~ " │ "
    assert {:ok, %Target{layout: :side_by_side, hunk: ^second}} = GitDiff.target(state, diff)
    assert {:error, :no_hunk} = GitDiff.navigate(state, diff, :next)
    assert {:ok, state} = GitDiff.navigate(state, diff, :previous)
    assert {:ok, %Target{hunk: ^first}} = GitDiff.target(state, diff)

    assert diff |> Buffer.decorations() |> Decorations.highlights_for_lines(0, 0) != []
  end

  @tag :tmp_dir
  test "a save refreshes only working views of that exact source without activating them", %{
    tmp_dir: root
  } do
    path = Path.join(root, "file.txt")
    working = "working\n"
    File.write!(path, working)
    source = start_file_buffer(path)
    unrelated_source = start_file_buffer(path)
    state = TestHelpers.gui_state()

    origin = %Origin{
      git_root: root,
      rel_path: "file.txt",
      section: :unstaged,
      source_buffer: source
    }

    assert {:ok, state} = GitDiff.open(state, origin, {"base\n", working})
    working_diff = EditorAPI.active_buffer(state)
    assert {:ok, state} = GitDiff.set_layout(state, working_diff, :side_by_side)
    assert {:ok, state} = GitDiff.open(state, origin, {"other base\n", working})
    other_working_diff = EditorAPI.active_buffer(state)

    assert {:ok, state} =
             GitDiff.open(state, %{origin | section: :staged}, {"base\n", "indexed\n"})

    staged_diff = EditorAPI.active_buffer(state)
    detached = %{origin | source_buffer: nil}
    assert {:ok, state} = GitDiff.open(state, detached, {"base\n", working})
    detached_diff = EditorAPI.active_buffer(state)

    assert :ok = Buffer.replace_content(source, "saved version\n")

    assert {:error, {:stale_source, %Target{origin: ^origin, hunk: nil}}} =
             GitDiff.target(state, working_diff)

    assert ^state = GitDiff.refresh_saved(state, unrelated_source)
    assert Buffer.content(working_diff) =~ "working"
    state = GitDiff.refresh_saved(state, source)
    assert EditorAPI.active_buffer(state) == detached_diff

    assert {:ok,
            %Target{
              layout: :side_by_side,
              contents: {"base\n", "saved version\n"},
              source_version: version
            }} = GitDiff.target(state, working_diff)

    assert version == Buffer.version(source)
    assert Buffer.content(working_diff) =~ "saved version"

    assert {:ok, %Target{contents: {"other base\n", "saved version\n"}}} =
             GitDiff.target(state, other_working_diff)

    assert {:ok, %Target{contents: {"base\n", "indexed\n"}, source_version: nil}} =
             GitDiff.target(state, staged_diff)

    assert {:ok, %Target{contents: {"base\n", ^working}}} = GitDiff.target(state, detached_diff)

    assert :ok = Buffer.retarget_path(source, Path.join(root, "renamed.txt"))
    assert ^state = GitDiff.refresh_saved(state, source)

    assert {:error, {:stale_source, %Target{origin: ^origin, hunk: nil}}} =
             GitDiff.target(state, working_diff)
  end

  @tag :tmp_dir
  test "switching section preserves the layout and retires the old generated buffer", %{
    tmp_dir: root
  } do
    state = TestHelpers.gui_state()
    origin = %Origin{git_root: root, rel_path: "deleted.txt", section: :unstaged}

    assert {:ok, state} = GitDiff.open(state, origin, {"old contents\n", "working\n"})
    original_diff = EditorAPI.active_buffer(state)
    assert {:ok, state} = GitDiff.set_layout(state, original_diff, :side_by_side)
    assert {:ok, state} = GitDiff.replace(state, original_diff, :staged, {"old contents\n", ""})

    staged_diff = EditorAPI.active_buffer(state)
    assert staged_diff != original_diff
    refute Process.alive?(original_diff)
    assert GitDiff.target(state, original_diff) == nil
    assert Buffer.buffer_name(staged_diff) == "deleted.txt [diff:staged]"
    assert Buffer.content(staged_diff) =~ "old contents"
    assert Buffer.content(staged_diff) =~ " │ "
    refute Buffer.content(staged_diff) =~ "working"

    assert {:ok,
            %Target{
              origin: %Origin{section: :staged},
              layout: :side_by_side,
              hunk: %Hunk{change: %{type: :deleted}}
            }} = GitDiff.target(state, staged_diff)
  end

  @tag :tmp_dir
  test "TUI rejects side-by-side and stale input never installs a diff", %{tmp_dir: root} do
    path = Path.join(root, "file.txt")
    File.write!(path, "actual\n")
    source = start_file_buffer(path)

    origin = %Origin{
      git_root: root,
      rel_path: "file.txt",
      section: :unstaged,
      source_buffer: source
    }

    state = TestHelpers.base_state()

    assert {:error, :stale_source} = GitDiff.open(state, origin, {"base\n", "old snapshot\n"})
    assert GitDiff.target(state, source) == nil
    assert {:ok, state} = GitDiff.open(state, origin, {"base\n", "actual\n"})
    diff = EditorAPI.active_buffer(state)
    assert {:error, :unsupported_layout} = GitDiff.set_layout(state, diff, :side_by_side)

    assert {:error, :stale_source} =
             GitDiff.replace(state, diff, :unstaged, {"base\n", "wrong\n"})

    assert {:ok, %Target{layout: :unified, contents: {"base\n", "actual\n"}}} =
             GitDiff.target(state, diff)
  end

  @tag :tmp_dir
  test "a symlink alias can open a working diff, but retargeting makes it stale", %{tmp_dir: root} do
    path = Path.join(root, "file.txt")
    link = Path.join(root, "alias.txt")
    other = Path.join(root, "other.txt")
    working = "working\n"
    File.write!(path, working)
    File.write!(other, working)
    File.ln_s!(path, link)

    source = start_file_buffer(link)
    version = Buffer.version(source)

    origin = %Origin{
      git_root: root,
      rel_path: "file.txt",
      section: :unstaged,
      source_buffer: source
    }

    assert {:ok, state} = GitDiff.open(TestHelpers.base_state(), origin, {"base\n", working})
    diff = EditorAPI.active_buffer(state)
    assert {:ok, %Target{origin: ^origin, source_version: ^version}} = GitDiff.target(state, diff)

    assert :ok = Buffer.retarget_path(source, other)
    assert Buffer.version(source) == version

    assert {:error, {:stale_source, %Target{origin: ^origin, hunk: nil}}} =
             GitDiff.target(state, diff)
  end

  @spec start_file_buffer(String.t()) :: pid()
  defp start_file_buffer(path) do
    {:ok, source} = Buffer.start_link(file_path: path)
    source
  end
end
