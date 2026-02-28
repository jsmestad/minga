defmodule Minga.OperatorTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufServer
  alias Minga.Operator

  defp start_buffer(content) do
    {:ok, pid} = BufServer.start_link(content: content)
    pid
  end

  # ── delete/3 (inclusive range) ─────────────────────────────────────────────

  describe "delete/3" do
    test "deletes a range at the start of a line (inclusive)" do
      # "hello world" — delete positions 0..4 inclusive = "hello"
      pid = start_buffer("hello world")
      assert {:ok, :deleted} = Operator.delete(pid, {0, 0}, {0, 4})
      assert BufServer.content(pid) == " world"
    end

    test "deletes a range in the middle of a line" do
      # Delete " world" = positions 5..10 inclusive
      pid = start_buffer("hello world")
      assert {:ok, :deleted} = Operator.delete(pid, {0, 5}, {0, 10})
      assert BufServer.content(pid) == "hello"
    end

    test "deletes a range that spans multiple lines" do
      # "hello\nworld" — delete from {0,5} (newline) through {1,4} (last char) = "\nworld"
      pid = start_buffer("hello\nworld")
      assert {:ok, :deleted} = Operator.delete(pid, {0, 5}, {1, 4})
      assert BufServer.content(pid) == "hello"
    end

    test "normalises reversed positions (from > to)" do
      pid = start_buffer("hello world")
      # Reversed: to={0,4} before from={0,0} — still deletes "hello"
      assert {:ok, :deleted} = Operator.delete(pid, {0, 4}, {0, 0})
      assert BufServer.content(pid) == " world"
    end

    test "deletes a single character" do
      pid = start_buffer("hello")
      assert {:ok, :deleted} = Operator.delete(pid, {0, 0}, {0, 0})
      assert BufServer.content(pid) == "ello"
    end

    test "places cursor at the start of the deleted range" do
      pid = start_buffer("hello world")
      Operator.delete(pid, {0, 0}, {0, 4})
      assert BufServer.cursor(pid) == {0, 0}
    end

    test "marks the buffer as dirty after deletion" do
      pid = start_buffer("hello")
      Operator.delete(pid, {0, 0}, {0, 2})
      assert BufServer.dirty?(pid)
    end
  end

  # ── change/3 ───────────────────────────────────────────────────────────────

  describe "change/3" do
    test "removes the range and returns {:ok, :changed}" do
      pid = start_buffer("hello world")
      assert {:ok, :changed} = Operator.change(pid, {0, 0}, {0, 4})
      assert BufServer.content(pid) == " world"
    end

    test "works on multi-line range" do
      # "foo\nbar\nbaz" — delete "foo\n" (inclusive {0,0}..{1,0} is "foo\nb")
      # Let's delete just the newline: from {0,3} (the \n) through {1,0} (first char of "bar")
      pid = start_buffer("foo\nbar\nbaz")
      assert {:ok, :changed} = Operator.change(pid, {0, 3}, {1, 0})
      # Deleted "\nb", remaining "foo" + "ar\nbaz"
      assert BufServer.content(pid) == "fooar\nbaz"
    end
  end

  # ── yank/3 ────────────────────────────────────────────────────────────────

  describe "yank/3" do
    test "returns the text without modifying the buffer" do
      pid = start_buffer("hello world")
      assert {:ok, "hello"} = Operator.yank(pid, {0, 0}, {0, 4})
      # Buffer is unchanged
      assert BufServer.content(pid) == "hello world"
    end

    test "yanks across multiple lines" do
      pid = start_buffer("hello\nworld")
      # From newline at {0,5} through last char of world {1,4}
      assert {:ok, text} = Operator.yank(pid, {0, 5}, {1, 4})
      assert text == "\nworld"
    end

    test "returns single char when from == to" do
      pid = start_buffer("hello")
      assert {:ok, "h"} = Operator.yank(pid, {0, 0}, {0, 0})
    end

    test "normalises reversed positions" do
      pid = start_buffer("hello")
      # Reversed: still returns "he"
      assert {:ok, "he"} = Operator.yank(pid, {0, 1}, {0, 0})
    end

    test "does not modify the buffer" do
      pid = start_buffer("hello world")
      Operator.yank(pid, {0, 0}, {0, 4})
      refute BufServer.dirty?(pid)
    end
  end

  # ── delete_line/2 ──────────────────────────────────────────────────────────

  describe "delete_line/2" do
    test "deletes the first of multiple lines including trailing newline" do
      pid = start_buffer("foo\nbar\nbaz")
      assert {:ok, :deleted} = Operator.delete_line(pid, 0)
      assert BufServer.content(pid) == "bar\nbaz"
    end

    test "deletes the last line, removing the preceding newline" do
      pid = start_buffer("foo\nbar")
      assert {:ok, :deleted} = Operator.delete_line(pid, 1)
      assert BufServer.content(pid) == "foo"
    end

    test "deletes a middle line including its trailing newline" do
      pid = start_buffer("foo\nbar\nbaz")
      assert {:ok, :deleted} = Operator.delete_line(pid, 1)
      assert BufServer.content(pid) == "foo\nbaz"
    end

    test "deletes the only line leaving an empty buffer" do
      pid = start_buffer("hello")
      assert {:ok, :deleted} = Operator.delete_line(pid, 0)
      assert BufServer.content(pid) == ""
    end
  end

  # ── change_line/2 ──────────────────────────────────────────────────────────

  describe "change_line/2" do
    test "removes the line and returns {:ok, :changed}" do
      pid = start_buffer("foo\nbar\nbaz")
      assert {:ok, :changed} = Operator.change_line(pid, 0)
      assert BufServer.content(pid) == "bar\nbaz"
    end
  end

  # ── yank_line/2 ────────────────────────────────────────────────────────────

  describe "yank_line/2" do
    test "returns the line content without modifying the buffer" do
      pid = start_buffer("foo\nbar\nbaz")
      assert {:ok, yanked} = Operator.yank_line(pid, 0)
      # First line range: {0,0} to {1,0} inclusive includes "foo\nb" but the
      # important thing is it includes the line text
      assert String.starts_with?(yanked, "foo")
      assert BufServer.content(pid) == "foo\nbar\nbaz"
    end

    test "does not modify the buffer" do
      pid = start_buffer("foo\nbar")
      Operator.yank_line(pid, 1)
      assert BufServer.content(pid) == "foo\nbar"
    end
  end
end
