defmodule Minga.Buffer.ForkTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.FileMutation
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

  test "selecting an EOF newline keeps its origin after rejecting the other edit" do
    parent = start_parent!("base\nlast")
    {:ok, fork} = Fork.create(parent)
    identity = {:fork, "/eof-origin"}
    writer = Minga.Buffer.EditSource.minga("writer", "old-step")
    revision = FileMutation.revision("base\nlast", 0, identity)
    operation = {:edit, [{"base", "fork"}, {"", "\n"}]}
    assert {:ok, _} = Fork.conditional_mutate(fork, revision, operation, identity, writer)
    assert {_, [{0, 4, {^writer, at}}, {9, 1, {^writer, at}}]} = Fork.staged_content(fork)

    BufferProcess.replace_content(parent, "user\nlast")
    assert {:ok, reviewed, _regions} = Fork.conflict_snapshot(fork)
    test = self()

    assert {:ok, "user\nlast\n"} =
             Fork.publish_resolution(fork, reviewed, [:rejected], fn _ancestor, selected ->
               send(test, {:selected, selected})
               :ok
             end)

    assert_receive {:selected, {"base\nlast\n", [{9, 1, {^writer, ^at}}]}}
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

    test "a later writer replaces only its bytes and undo restores the previous exact origin" do
      parent = start_parent!("old -- old")
      {:ok, fork} = Fork.create(parent)
      identity = {:fork, "/origins"}
      a = {:minga, "task-a", "step-1"}
      b = {:minga, "task-b", "step-2"}

      rev = FileMutation.revision("old -- old", 0, identity)

      assert {:ok, _} =
               Fork.conditional_mutate(fork, rev, {:edit, [{"old --", "αβ --"}]}, identity, a)

      assert {"αβ -- old", [{0, 7, {^a, at_a}}]} = Fork.staged_content(fork)
      assert is_integer(at_a)

      rev = FileMutation.revision("αβ -- old", 1, identity)
      assert {:ok, _} = Fork.conditional_mutate(fork, rev, {:edit, [{"β", "B!"}]}, identity, b)

      assert {"αB! -- old", [{0, 2, {^a, ^at_a}}, {2, 2, {^b, at_b}}, {4, 3, {^a, ^at_a}}]} =
               Fork.staged_content(fork)

      assert is_integer(at_b)
      assert {:error, :stale_revision} = Fork.conditional_mutate(fork, rev, :delete, identity, b)
      assert :ok = Fork.undo(fork)
      assert {"αβ -- old", [{0, 7, {^a, ^at_a}}]} = Fork.staged_content(fork)
    end

    test "a unique legacy deletion removes the right origin even when the remaining bytes match" do
      parent = start_parent!("a")
      {:ok, fork} = Fork.create(parent)
      identity = {:fork, "/duplicate"}
      first = Minga.Buffer.EditSource.minga("first", "replace")
      second = Minga.Buffer.EditSource.minga("second", "append")

      assert {:ok, _} =
               Fork.conditional_mutate(
                 fork,
                 FileMutation.revision("a", 0, identity),
                 {:edit, [{"a", "x"}]},
                 identity,
                 first
               )

      assert {"x", [{0, 1, {^first, time}}]} = Fork.staged_content(fork)

      assert {:ok, _} =
               Fork.conditional_mutate(
                 fork,
                 FileMutation.revision("x", 1, identity),
                 {:edit, [{"", "x"}]},
                 identity,
                 second
               )

      assert {:ok, _} = Fork.find_and_replace(fork, "\nx", "")
      assert {"x", [{0, 1, {^first, ^time}}]} = Fork.staged_content(fork)
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
