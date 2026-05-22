defmodule MingaEditor.UI.Picker.GitLogSourceTest do
  @moduledoc "Tests for the git log picker source."

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.GitLogFileSource
  alias MingaEditor.UI.Picker.GitLogSource

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    GitStub.set_root(dir, dir)
    on_exit(fn -> GitStub.clear(dir) end)
    %{root: dir, ctx: context(dir)}
  end

  test "candidates show commit message, hash annotation, author, and date", %{
    root: root,
    ctx: ctx
  } do
    GitStub.set_log(root, [
      commit("abc123456789", "abc1234", "Ada", "2 days ago", "Add picker preview")
    ])

    assert [item] = GitLogSource.candidates(ctx)
    assert item.label == "Add picker preview"
    assert item.annotation == "abc1234"
    assert item.description == "Ada · 2 days ago"
  end

  test "commits are searchable by message, author, and hash", %{root: root, ctx: ctx} do
    GitStub.set_log(root, [
      commit("abc123456789", "abc1234", "Ada", "2 days ago", "Add picker preview")
    ])

    items = GitLogSource.candidates(ctx)

    assert Picker.new(items) |> Picker.filter("preview") |> Picker.count() == 1
    assert Picker.new(items) |> Picker.filter("Ada") |> Picker.count() == 1
    assert Picker.new(items) |> Picker.filter("abc123456789") |> Picker.count() == 1
  end

  test "candidate list includes a load more item when more commits exist", %{root: root, ctx: ctx} do
    entries =
      Enum.map(1..51, fn n -> commit("hash#{n}", "h#{n}", "Ada", "today", "Commit #{n}") end)

    GitStub.set_log(root, entries)

    items = GitLogSource.candidates(ctx)

    assert length(items) == 51
    assert List.last(items).label == "Load more..."
  end

  test "preview returns styled diff lines for the selected commit", %{root: root, ctx: ctx} do
    GitStub.set_log(root, [commit("abc123456789", "abc1234", "Ada", "today", "Edit")])

    GitStub.set_diff(
      root,
      [commit: "abc123456789"],
      "diff --git a/a b/a\n@@ -1 +1 @@\n-old\n+new"
    )

    [item] = GitLogSource.candidates(ctx)

    assert [
             [{"diff --git a/a b/a", _header_color, true}],
             [{"@@ -1 +1 @@", _hunk_color, true}],
             [{"-old", _deleted_color, false}],
             [{"+new", _added_color, false}]
           ] = GitLogSource.preview(item, ctx)
  end

  test "file source filters commits to the active buffer path", %{root: root, ctx: ctx} do
    rel_path = "lib/demo.ex"
    abs_path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(abs_path))
    File.write!(abs_path, "new\n")

    entry = commit("filehash", "file123", "Ada", "today", "Edit current file")
    GitStub.set_head(root, rel_path, "old\n")
    GitStub.set_log(root, [count: 51, path: rel_path], [entry])

    {:ok, source_buf} = Buffer.start_link(content: "new\n")

    {:ok, git_buf} =
      Minga.Git.Buffer.start_link(
        git_root: root,
        file_path: abs_path,
        initial_content: "new\n"
      )

    put_tracking(source_buf, git_buf)
    file_ctx = %{ctx | buffers: %Buffers{active: source_buf, list: [source_buf]}}

    assert [item] = GitLogFileSource.candidates(file_ctx)
    assert item.label == "Edit current file"
  end

  defp context(root) do
    %Context{
      buffers: %Buffers{},
      editing: nil,
      search: nil,
      viewport: nil,
      tab_bar: nil,
      picker_ui: %PickerState{context: %{git_root: root}},
      capabilities: %{},
      theme: %{fg: 0xCCCCCC}
    }
  end

  defp commit(hash, short_hash, author, date, message) do
    %Git.LogEntry{
      hash: hash,
      short_hash: short_hash,
      author: author,
      date: date,
      message: message
    }
  end

  defp put_tracking(source_buf, git_buf) do
    table = Minga.Git.Tracker.Registry

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ets.insert(table, {source_buf, git_buf})
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table, source_buf) end)
  end
end
