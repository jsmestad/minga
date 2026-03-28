defmodule Minga.Buffer.ForkTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Fork
  alias Minga.Buffer.Server

  defp start_parent!(content) do
    start_supervised!({Server, content: content}, id: make_ref())
  end

  describe "create/1 and content/1" do
    test "fork content matches parent at creation" do
      parent = start_parent!("hello\nworld")

      {:ok, fork} = Fork.create(parent)

      assert Fork.content(fork) == "hello\nworld"
      assert Fork.content(fork) == Server.content(parent)
    end

    test "fork starts clean and at version 0" do
      parent = start_parent!("test")

      {:ok, fork} = Fork.create(parent)

      refute Fork.dirty?(fork)
      assert Fork.version(fork) == 0
    end
  end

  describe "editing" do
    test "editing fork does not affect parent" do
      parent = start_parent!("hello\nworld")

      {:ok, fork} = Fork.create(parent)
      GenServer.call(fork, {:replace_content, "new content", :agent})

      assert Fork.content(fork) == "new content"
      assert Server.content(parent) == "hello\nworld"
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

    test "find_and_replace_batch applies multiple edits" do
      parent = start_parent!("aaa bbb ccc")

      {:ok, fork} = Fork.create(parent)
      edits = [{"aaa", "AAA"}, {"ccc", "CCC"}]
      {:ok, results} = GenServer.call(fork, {:find_and_replace_batch, edits, nil})

      assert [{:ok, _}, {:ok, _}] = results
      assert Fork.content(fork) == "AAA bbb CCC"
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

    test "find_and_replace_batch with all failures does not mark dirty" do
      parent = start_parent!("hello")

      {:ok, fork} = Fork.create(parent)
      edits = [{"missing1", "X"}, {"missing2", "Y"}]
      {:ok, results} = GenServer.call(fork, {:find_and_replace_batch, edits, nil})

      assert [{:error, _}, {:error, _}] = results
      refute Fork.dirty?(fork)
      assert Fork.version(fork) == 0
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
      Server.replace_content(parent, "parent changed")

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
      Server.replace_content(parent, "line1\nparent_changed\nline3")

      assert {:ok, "line1\nparent_changed\nline3"} = Fork.merge(fork)
    end

    test "merge with non-overlapping changes from both sides" do
      parent = start_parent!("a\nb\nc\nd\ne")

      {:ok, fork} = Fork.create(parent)
      GenServer.call(fork, {:find_and_replace, "b", "fork_b", nil})
      Server.replace_content(parent, "a\nb\nc\nparent_d\ne")

      assert {:ok, merged} = Fork.merge(fork)
      assert merged =~ "fork_b"
      assert merged =~ "parent_d"
    end

    test "merge with conflicting changes returns conflict hunks" do
      parent = start_parent!("a\nb\nc")

      {:ok, fork} = Fork.create(parent)
      GenServer.call(fork, {:find_and_replace, "b", "fork_b", nil})
      Server.replace_content(parent, "a\nparent_b\nc")

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
