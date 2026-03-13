defmodule Minga.Agent.DiffSnapshotTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.DiffSnapshot

  describe "from_content/1" do
    test "small content stays in memory" do
      snap = DiffSnapshot.from_content("hello\nworld")
      assert {:memory, _} = snap
    end

    test "content returns original text for memory snapshot" do
      snap = DiffSnapshot.from_content("hello\nworld")
      assert DiffSnapshot.content(snap) == "hello\nworld"
    end

    test "lines returns split lines for memory snapshot" do
      snap = DiffSnapshot.from_content("a\nb\nc")
      assert DiffSnapshot.lines(snap) == ["a", "b", "c"]
    end

    test "cleanup is a no-op for memory snapshots" do
      snap = DiffSnapshot.from_content("hello")
      assert :ok = DiffSnapshot.cleanup(snap)
    end
  end

  describe "file-backed snapshots" do
    test "file snapshot can be read back" do
      # Create a file snapshot directly
      dir = System.tmp_dir!()
      path = Path.join(dir, "test_snap_#{:erlang.unique_integer([:positive])}.tmp")
      content = "line1\nline2\nline3"
      File.write!(path, content)

      snap = {:file, path}

      assert DiffSnapshot.content(snap) == content
      assert DiffSnapshot.lines(snap) == ["line1", "line2", "line3"]

      assert :ok = DiffSnapshot.cleanup(snap)
      refute File.exists?(path)
    end
  end
end
