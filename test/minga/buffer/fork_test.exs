defmodule Minga.Buffer.ForkTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Fork
  alias Minga.Buffer.Process, as: BufferProcess

  defp start_parent!(content) do
    start_supervised!({BufferProcess, content: content}, id: make_ref())
  end

  test "conflict publication refuses stale parent and fork snapshots without staging" do
    parent = start_parent!("base")
    {:ok, fork} = Fork.create(parent)
    GenServer.call(fork, {:replace_content, "fork", :agent})
    BufferProcess.replace_content(parent, "human")
    assert {:ok, revision, [_conflict]} = Fork.conflict_snapshot(fork)
    staging = fn _, _ -> flunk("stale review reached staging") end

    BufferProcess.replace_content(parent, "new human")
    assert {:error, :stale_parent} = Fork.publish_resolution(fork, revision, [:accepted], staging)

    assert {:ok, revision, [_conflict]} = Fork.conflict_snapshot(fork)
    GenServer.call(fork, {:replace_content, "new fork", :agent})
    assert {:error, :stale_fork} = Fork.publish_resolution(fork, revision, [:accepted], staging)
    assert BufferProcess.content(parent) == "new human"
    refute Fork.published?(fork)
  end

  describe "create/1 and content/1" do
    test "fork content matches parent at creation" do
      parent = start_parent!("hello\nworld")

      {:ok, fork} = Fork.create(parent)

      assert Fork.content(fork) == "hello\nworld"
      assert Fork.content(fork) == BufferProcess.content(parent)
    end

    test "fork starts clean and at version 0" do
      parent = start_parent!("test")

      {:ok, fork} = Fork.create(parent)

      refute Fork.dirty?(fork)
      assert Fork.version(fork) == 0
    end

    test "bounded line snapshots include the fork version" do
      parent = start_parent!("zero\none\ntwo")
      {:ok, fork} = Fork.create(parent)

      assert {"one", 1, 3, 0, true} =
               Fork.content_on_lines_with_version(fork, 1, 1, 100)

      GenServer.call(fork, {:replace_content, "zero\nchanged\ntwo", :agent})

      assert {"chang", 1, 3, 1, false} =
               Fork.content_on_lines_with_version(fork, 1, 1, 5)
    end
  end

  describe "editing" do
    test "editing fork does not affect parent" do
      parent = start_parent!("hello\nworld")

      {:ok, fork} = Fork.create(parent)
      GenServer.call(fork, {:replace_content, "new content", :agent})

      assert Fork.content(fork) == "new content"
      assert BufferProcess.content(parent) == "hello\nworld"
    end

    test "editing fork marks it dirty and increments version" do
      parent = start_parent!("test")

      {:ok, fork} = Fork.create(parent)
      GenServer.call(fork, {:replace_content, "changed", :agent})

      assert Fork.dirty?(fork)
      assert Fork.version(fork) == 1
    end

    test "find_and_replace updates fork content" do
      parent = start_parent!("hello world")

      {:ok, fork} = Fork.create(parent)
      assert {:ok, "applied"} = GenServer.call(fork, {:find_and_replace, "hello", "goodbye", nil})

      assert Fork.content(fork) == "goodbye world"
      assert Fork.dirty?(fork)
      assert Fork.version(fork) == 1
    end

    test "find_and_replace with ambiguous match returns error" do
      parent = start_parent!("foo\nbar\nfoo")

      {:ok, fork} = Fork.create(parent)
      assert {:error, msg} = GenServer.call(fork, {:find_and_replace, "foo", "X", nil})
      assert msg =~ "2 times"
      refute Fork.dirty?(fork)
      assert Fork.version(fork) == 0
    end

    test "find_and_replace honors boundaries" do
      parent = start_parent!("line1\ntarget\nline3")

      {:ok, fork} = Fork.create(parent)

      assert {:error, msg} =
               GenServer.call(fork, {:find_and_replace, "target", "changed", {0, 0}})

      assert msg =~ "edit outside boundary"
      refute Fork.dirty?(fork)
      assert Fork.version(fork) == 0

      assert {:ok, "applied"} =
               GenServer.call(fork, {:find_and_replace, "target", "changed", {1, 1}})

      assert Fork.content(fork) == "line1\nchanged\nline3"
      assert Fork.dirty?(fork)
      assert Fork.version(fork) == 1
    end

    test "version increments on each edit operation" do
      parent = start_parent!("aaa bbb ccc")

      {:ok, fork} = Fork.create(parent)
      GenServer.call(fork, {:replace_content, "first", :agent})
      GenServer.call(fork, {:replace_content, "second", :agent})
      GenServer.call(fork, {:find_and_replace, "second", "third", nil})

      assert Fork.version(fork) == 3
    end
  end

  describe "ancestor_content/1" do
    test "returns the snapshot at fork time" do
      parent = start_parent!("original content")

      {:ok, fork} = Fork.create(parent)

      # Edit both fork and parent
      GenServer.call(fork, {:replace_content, "fork changed", :agent})
      BufferProcess.replace_content(parent, "parent changed")

      assert Fork.ancestor_content(fork) == "original content"
    end
  end

  describe "merge/1" do
    test "merge when only fork changed returns fork content" do
      parent = start_parent!("line1\nline2\nline3")

      {:ok, fork} = Fork.create(parent)
      GenServer.call(fork, {:find_and_replace, "line2", "changed", nil})

      assert {:ok, "line1\nchanged\nline3"} = Fork.merge(fork)
    end

    test "merge when only parent changed returns parent content" do
      parent = start_parent!("line1\nline2\nline3")

      {:ok, fork} = Fork.create(parent)
      BufferProcess.replace_content(parent, "line1\nparent_changed\nline3")

      assert {:ok, "line1\nparent_changed\nline3"} = Fork.merge(fork)
    end

    test "merge with non-overlapping changes from both sides" do
      parent = start_parent!("a\nb\nc\nd\ne")

      {:ok, fork} = Fork.create(parent)
      GenServer.call(fork, {:find_and_replace, "b", "fork_b", nil})
      BufferProcess.replace_content(parent, "a\nb\nc\nparent_d\ne")

      assert {:ok, merged} = Fork.merge(fork)
      assert merged =~ "fork_b"
      assert merged =~ "parent_d"
    end

    test "merge with conflicting changes returns conflict hunks" do
      parent = start_parent!("a\nb\nc")

      {:ok, fork} = Fork.create(parent)
      GenServer.call(fork, {:find_and_replace, "b", "fork_b", nil})
      BufferProcess.replace_content(parent, "a\nparent_b\nc")

      assert {:conflict, hunks} = Fork.merge(fork)
      assert Enum.any?(hunks, &match?({:conflict, _, _}, &1))
    end

    test "merge with no edits on either side returns original" do
      parent = start_parent!("unchanged")

      {:ok, fork} = Fork.create(parent)

      assert {:ok, "unchanged"} = Fork.merge(fork)
    end

    test "merge returns {:error, :parent_dead} when parent died" do
      parent = start_parent!("test")

      {:ok, fork} = Fork.create(parent)

      # Stop the parent
      GenServer.stop(parent)

      # Synchronize: ensure fork has processed the :DOWN message
      :sys.get_state(fork)

      assert {:error, :parent_dead} = Fork.merge(fork)
    end
  end

  describe "edge cases" do
    test "fork from empty parent" do
      parent = start_parent!("")

      {:ok, fork} = Fork.create(parent)
      assert Fork.content(fork) == ""
      refute Fork.dirty?(fork)

      assert {:ok, ""} = Fork.merge(fork)
    end
  end
end
