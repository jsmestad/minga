defmodule Minga.Input.VimTest do
  use ExUnit.Case, async: true

  alias Minga.Input.TextField
  alias Minga.Input.Vim

  # Helper to create a vim+textfield pair in normal mode
  defp normal(text, cursor \\ {0, 0}) do
    tf = TextField.new(text) |> TextField.set_cursor(cursor)
    vim = %Vim{state: :normal}
    {vim, tf}
  end

  # Helper: send a sequence of keys (codepoint, 0 mods)
  defp keys({vim, tf}, cps) when is_list(cps) do
    Enum.reduce(cps, {vim, tf}, fn cp, {v, t} ->
      {:handled, v2, t2} = Vim.handle_key(v, t, cp, 0)
      {v2, t2}
    end)
  end

  defp key({vim, tf}, cp, mods \\ 0) do
    Vim.handle_key(vim, tf, cp, mods)
  end

  # ── Mode transitions ──────────────────────────────────────────────────

  describe "mode transitions" do
    test "i enters insert mode" do
      {vim, tf} = normal("hello")
      {:handled, vim, _tf} = key({vim, tf}, ?i)
      assert Vim.mode(vim) == :insert
    end

    test "a enters insert mode after cursor" do
      {vim, tf} = normal("hello", {0, 2})
      {:handled, vim, tf} = key({vim, tf}, ?a)
      assert Vim.mode(vim) == :insert
      assert tf.cursor == {0, 3}
    end

    test "A enters insert mode at end of line" do
      {vim, tf} = normal("hello", {0, 0})
      {:handled, vim, tf} = key({vim, tf}, ?A)
      assert Vim.mode(vim) == :insert
      assert tf.cursor == {0, 5}
    end

    test "I enters insert mode at start of line" do
      {vim, tf} = normal("hello", {0, 3})
      {:handled, vim, tf} = key({vim, tf}, ?I)
      assert Vim.mode(vim) == :insert
      assert tf.cursor == {0, 0}
    end

    test "o opens line below and enters insert" do
      {vim, tf} = normal("hello\nworld", {0, 2})
      {:handled, vim, tf} = key({vim, tf}, ?o)
      assert Vim.mode(vim) == :insert
      assert tf.cursor == {1, 0}
      assert TextField.line_count(tf) == 3
    end

    test "O opens line above and enters insert" do
      {vim, tf} = normal("hello\nworld", {1, 0})
      {:handled, vim, tf} = key({vim, tf}, ?O)
      assert Vim.mode(vim) == :insert
      assert tf.cursor == {1, 0}
      assert TextField.line_count(tf) == 3
    end

    test "enter_normal clamps cursor past end of line" do
      tf = TextField.new("hi") |> TextField.set_cursor({0, 5})
      {_vim, tf} = Vim.enter_normal(%Vim{}, tf)
      assert tf.cursor == {0, 1}
    end

    test "v enters visual mode" do
      {vim, tf} = normal("hello", {0, 2})
      {:handled, vim, _tf} = key({vim, tf}, ?v)
      assert Vim.mode(vim) == :visual
      assert vim.visual_anchor == {0, 2}
    end

    test "V enters visual line mode" do
      {vim, tf} = normal("hello", {0, 2})
      {:handled, vim, _tf} = key({vim, tf}, ?V)
      assert Vim.mode(vim) == :visual_line
    end
  end

  # ── Motions ────────────────────────────────────────────────────────────

  describe "motions" do
    test "h moves left (no wrap)" do
      {vim, tf} = normal("hello", {0, 3})
      {:handled, _vim, tf} = key({vim, tf}, ?h)
      assert tf.cursor == {0, 2}
    end

    test "h at column 0 stays" do
      {vim, tf} = normal("hello", {0, 0})
      {:handled, _vim, tf} = key({vim, tf}, ?h)
      assert tf.cursor == {0, 0}
    end

    test "l moves right (clamped to last char)" do
      {vim, tf} = normal("hello", {0, 3})
      {:handled, _vim, tf} = key({vim, tf}, ?l)
      assert tf.cursor == {0, 4}
    end

    test "l at end of line stays" do
      {vim, tf} = normal("hello", {0, 4})
      {:handled, _vim, tf} = key({vim, tf}, ?l)
      assert tf.cursor == {0, 4}
    end

    test "j moves down" do
      {vim, tf} = normal("hello\nworld", {0, 2})
      {:handled, _vim, tf} = key({vim, tf}, ?j)
      assert tf.cursor == {1, 2}
    end

    test "j at last line stays" do
      {vim, tf} = normal("hello", {0, 2})
      {:handled, _vim, tf} = key({vim, tf}, ?j)
      assert tf.cursor == {0, 2}
    end

    test "k moves up" do
      {vim, tf} = normal("hello\nworld", {1, 2})
      {:handled, _vim, tf} = key({vim, tf}, ?k)
      assert tf.cursor == {0, 2}
    end

    test "w moves to next word" do
      {vim, tf} = normal("hello world", {0, 0})
      {:handled, _vim, tf} = key({vim, tf}, ?w)
      assert tf.cursor == {0, 6}
    end

    test "b moves to previous word" do
      {vim, tf} = normal("hello world", {0, 6})
      {:handled, _vim, tf} = key({vim, tf}, ?b)
      assert tf.cursor == {0, 0}
    end

    test "e moves to end of word" do
      {vim, tf} = normal("hello world", {0, 0})
      {:handled, _vim, tf} = key({vim, tf}, ?e)
      assert tf.cursor == {0, 4}
    end

    test "0 moves to start of line" do
      {vim, tf} = normal("hello", {0, 3})
      {:handled, _vim, tf} = key({vim, tf}, ?0)
      assert tf.cursor == {0, 0}
    end

    test "$ moves to end of line" do
      {vim, tf} = normal("hello", {0, 0})
      {:handled, _vim, tf} = key({vim, tf}, ?$)
      assert tf.cursor == {0, 4}
    end

    test "^ moves to first non-blank" do
      {vim, tf} = normal("  hello", {0, 0})
      {:handled, _vim, tf} = key({vim, tf}, ?^)
      assert tf.cursor == {0, 2}
    end

    test "gg goes to start of document" do
      {vim, tf} = normal("hello\nworld", {1, 3})
      {_vim, tf} = keys({vim, tf}, [?g, ?g])
      assert tf.cursor == {0, 0}
    end

    test "G goes to last line" do
      {vim, tf} = normal("one\ntwo\nthree", {0, 0})
      {:handled, _vim, tf} = key({vim, tf}, ?G)
      assert {2, _} = tf.cursor
    end

    test "3G goes to line 3" do
      {vim, tf} = normal("one\ntwo\nthree\nfour", {0, 0})
      {_vim, tf} = keys({vim, tf}, [?3, ?G])
      assert {2, 0} = tf.cursor
    end
  end

  # ── Count prefixes ────────────────────────────────────────────────────

  describe "counts" do
    test "3j moves down 3 lines" do
      {vim, tf} = normal("a\nb\nc\nd\ne", {0, 0})
      {_vim, tf} = keys({vim, tf}, [?3, ?j])
      assert tf.cursor == {3, 0}
    end

    test "2w moves forward 2 words" do
      {vim, tf} = normal("one two three", {0, 0})
      {_vim, tf} = keys({vim, tf}, [?2, ?w])
      assert tf.cursor == {0, 8}
    end

    test "0 without count is line_start (not count digit)" do
      {vim, tf} = normal("hello", {0, 3})
      {:handled, _vim, tf} = key({vim, tf}, ?0)
      assert tf.cursor == {0, 0}
    end

    test "10j accumulates multi-digit count" do
      lines = Enum.map_join(0..15, "\n", &to_string/1)
      {vim, tf} = normal(lines, {0, 0})
      {_vim, tf} = keys({vim, tf}, [?1, ?0, ?j])
      assert tf.cursor == {10, 0}
    end
  end

  # ── Operators ──────────────────────────────────────────────────────────

  describe "operators" do
    test "x deletes character under cursor" do
      {vim, tf} = normal("hello", {0, 1})
      {:handled, vim, tf} = key({vim, tf}, ?x)
      assert TextField.content(tf) == "hllo"
      assert vim.register == "e"
    end

    test "X deletes character before cursor" do
      {vim, tf} = normal("hello", {0, 2})
      {:handled, _vim, tf} = key({vim, tf}, ?X)
      assert TextField.content(tf) == "hllo"
    end

    test "dd deletes current line" do
      {vim, tf} = normal("one\ntwo\nthree", {1, 0})
      {_vim, tf} = keys({vim, tf}, [?d, ?d])
      assert TextField.content(tf) == "one\nthree"
      assert tf.cursor == {1, 0}
    end

    test "2dd deletes 2 lines" do
      {vim, tf} = normal("one\ntwo\nthree\nfour", {0, 0})
      {_vim, tf} = keys({vim, tf}, [?2, ?d, ?d])
      assert TextField.content(tf) == "three\nfour"
    end

    test "dw deletes to next word" do
      {vim, tf} = normal("hello world", {0, 0})
      {vim2, tf} = keys({vim, tf}, [?d, ?w])
      assert TextField.content(tf) == "world"
      assert vim2.register == "hello "
    end

    test "de deletes to end of word (inclusive)" do
      {vim, tf} = normal("hello world", {0, 0})
      {_vim, tf} = keys({vim, tf}, [?d, ?e])
      assert TextField.content(tf) == " world"
    end

    test "d$ deletes to end of line" do
      {vim, tf} = normal("hello world", {0, 5})
      {_vim, tf} = keys({vim, tf}, [?d, ?$])
      assert TextField.content(tf) == "hello"
    end

    test "d0 deletes to start of line" do
      {vim, tf} = normal("hello world", {0, 6})
      {_vim, tf} = keys({vim, tf}, [?d, ?0])
      assert TextField.content(tf) == "world"
    end

    test "D deletes to end of line" do
      {vim, tf} = normal("hello world", {0, 5})
      {:handled, _vim, tf} = key({vim, tf}, ?D)
      assert TextField.content(tf) == "hello"
    end

    test "cc changes line (enters insert)" do
      {vim, tf} = normal("hello\nworld", {0, 2})
      {vim2, tf} = keys({vim, tf}, [?c, ?c])
      assert Vim.mode(vim2) == :insert
      assert TextField.content(tf) == "\nworld"
    end

    test "cw changes word (enters insert)" do
      {vim, tf} = normal("hello world", {0, 0})
      {vim2, tf} = keys({vim, tf}, [?c, ?w])
      assert Vim.mode(vim2) == :insert
      assert TextField.content(tf) == "world"
    end

    test "C changes to end of line" do
      {vim, tf} = normal("hello world", {0, 5})
      {:handled, vim, tf} = key({vim, tf}, ?C)
      assert Vim.mode(vim) == :insert
      assert TextField.content(tf) == "hello"
    end

    test "yy yanks the current line" do
      {vim, tf} = normal("hello\nworld", {0, 0})
      {vim2, _tf} = keys({vim, tf}, [?y, ?y])
      assert vim2.register == "hello"
    end

    test "yw yanks a word" do
      {vim, tf} = normal("hello world", {0, 0})
      {vim2, _tf} = keys({vim, tf}, [?y, ?w])
      assert vim2.register == "hello "
    end

    test "s substitutes character" do
      {vim, tf} = normal("hello", {0, 2})
      {:handled, vim, tf} = key({vim, tf}, ?s)
      assert Vim.mode(vim) == :insert
      assert TextField.content(tf) == "helo"
    end

    test "S substitutes line" do
      {vim, tf} = normal("hello\nworld", {0, 2})
      {:handled, vim, tf} = key({vim, tf}, ?S)
      assert Vim.mode(vim) == :insert
      assert TextField.content(tf) == "\nworld"
    end

    test "r replaces character under cursor" do
      {vim, tf} = normal("hello", {0, 1})
      {_vim, tf} = keys({vim, tf}, [?r, ?a])
      assert TextField.content(tf) == "hallo"
      assert tf.cursor == {0, 1}
    end
  end

  # ── Text objects ────────────────────────────────────────────────────────

  describe "text objects" do
    test "diw deletes inner word" do
      {vim, tf} = normal("hello world", {0, 2})
      {_vim, tf} = keys({vim, tf}, [?d, ?i, ?w])
      assert TextField.content(tf) == " world"
    end

    test "daw deletes a word (with trailing space)" do
      {vim, tf} = normal("hello world", {0, 2})
      {_vim, tf} = keys({vim, tf}, [?d, ?a, ?w])
      assert TextField.content(tf) == "world"
    end

    test "ci\" changes inner quotes" do
      {vim, tf} = normal(~s(say "hello" please), {0, 6})
      {vim2, tf} = keys({vim, tf}, [?c, ?i, ?"])
      assert Vim.mode(vim2) == :insert
      assert TextField.content(tf) == ~s(say "" please)
    end

    test "di( deletes inner parens" do
      {vim, tf} = normal("foo(bar baz)end", {0, 5})
      {_vim, tf} = keys({vim, tf}, [?d, ?i, ?(])
      assert TextField.content(tf) == "foo()end"
    end
  end

  # ── Find-char motions ──────────────────────────────────────────────────

  describe "find-char motions" do
    test "fo finds next 'o'" do
      {vim, tf} = normal("hello world", {0, 0})
      {_vim, tf} = keys({vim, tf}, [?f, ?o])
      assert tf.cursor == {0, 4}
    end

    test "Fo finds previous 'o'" do
      {vim, tf} = normal("hello world", {0, 8})
      {_vim, tf} = keys({vim, tf}, [?F, ?o])
      assert tf.cursor == {0, 7}
    end

    test "to finds till next 'o'" do
      {vim, tf} = normal("hello world", {0, 0})
      {_vim, tf} = keys({vim, tf}, [?t, ?o])
      assert tf.cursor == {0, 3}
    end

    test "dfo deletes through found char" do
      {vim, tf} = normal("hello world", {0, 0})
      {_vim, tf} = keys({vim, tf}, [?d, ?f, ?o])
      assert TextField.content(tf) == " world"
    end
  end

  # ── Paste ──────────────────────────────────────────────────────────────

  describe "paste" do
    test "p pastes after cursor" do
      {vim, tf} = normal("hello", {0, 4})
      vim = %{vim | register: " world"}
      {:handled, _vim, tf} = key({vim, tf}, ?p)
      assert TextField.content(tf) == "hello world"
    end

    test "P pastes before cursor" do
      {vim, tf} = normal("world", {0, 0})
      vim = %{vim | register: "hello "}
      {:handled, _vim, tf} = key({vim, tf}, ?P)
      assert TextField.content(tf) == "hello world"
    end

    test "dd then p restores line" do
      {vim, tf} = normal("one\ntwo\nthree", {1, 0})
      {vim, tf} = keys({vim, tf}, [?d, ?d])
      assert TextField.content(tf) == "one\nthree"
      {:handled, _vim, tf} = key({vim, tf}, ?p)
      assert TextField.content(tf) =~ "two"
    end
  end

  # ── Undo / Redo ────────────────────────────────────────────────────────

  describe "undo/redo" do
    test "u undoes the last change" do
      {vim, tf} = normal("hello world", {0, 0})
      {vim, tf} = keys({vim, tf}, [?d, ?w])
      assert TextField.content(tf) == "world"
      {:handled, _vim, tf} = key({vim, tf}, ?u)
      assert TextField.content(tf) == "hello world"
    end

    test "Ctrl+R redoes after undo" do
      {vim, tf} = normal("hello world", {0, 0})
      {vim, tf} = keys({vim, tf}, [?d, ?w])
      {:handled, vim, tf} = key({vim, tf}, ?u)
      assert TextField.content(tf) == "hello world"
      ctrl = Minga.Port.Protocol.mod_ctrl()
      {:handled, _vim, tf} = key({vim, tf}, ?r, ctrl)
      assert TextField.content(tf) == "world"
    end

    test "u with empty undo stack is no-op" do
      {vim, tf} = normal("hello")
      {:handled, _vim, tf} = key({vim, tf}, ?u)
      assert TextField.content(tf) == "hello"
    end
  end

  # ── Visual mode ────────────────────────────────────────────────────────

  describe "visual mode" do
    test "v + motion extends selection, d deletes it" do
      {vim, tf} = normal("hello world", {0, 0})
      # v at 0, move to end of word, delete
      {vim, tf} = keys({vim, tf}, [?v])
      assert Vim.mode(vim) == :visual
      {vim, tf} = keys({vim, tf}, [?e])
      assert tf.cursor == {0, 4}
      {_vim, tf} = keys({vim, tf}, [?d])
      assert TextField.content(tf) == " world"
    end

    test "V + d deletes full line" do
      {vim, tf} = normal("one\ntwo\nthree", {1, 0})
      {_vim, tf} = keys({vim, tf}, [?V, ?d])
      assert TextField.content(tf) == "one\nthree"
    end

    test "viw selects inner word" do
      {vim, tf} = normal("hello world", {0, 2})
      {vim, tf} = keys({vim, tf}, [?v, ?i, ?w])
      assert Vim.mode(vim) == :visual
      # Anchor should be at start of word, cursor at end
      {from, to} = Vim.visual_range(vim, tf)
      assert from == {0, 0}
      assert to == {0, 4}
    end

    test "Escape exits visual mode" do
      {vim, tf} = normal("hello", {0, 2})
      {vim, _tf} = keys({vim, tf}, [?v])
      assert Vim.mode(vim) == :visual
      {:handled, vim, _tf} = key({vim, tf}, 27)
      assert Vim.mode(vim) == :normal
    end
  end

  # ── Join lines ─────────────────────────────────────────────────────────

  describe "join lines" do
    test "J joins current line with next" do
      {vim, tf} = normal("hello\nworld", {0, 0})
      {:handled, _vim, tf} = key({vim, tf}, ?J)
      assert TextField.content(tf) == "hello world"
    end

    test "J at last line is no-op" do
      {vim, tf} = normal("hello", {0, 0})
      {:handled, _vim, tf} = key({vim, tf}, ?J)
      assert TextField.content(tf) == "hello"
    end
  end

  # ── Escape / not_handled ───────────────────────────────────────────────

  describe "key passthrough" do
    test "Escape in normal mode returns :not_handled" do
      {vim, tf} = normal("hello")
      assert :not_handled = key({vim, tf}, 27)
    end

    test "Ctrl+C in normal mode returns :not_handled" do
      {vim, tf} = normal("hello")
      ctrl = Minga.Port.Protocol.mod_ctrl()
      assert :not_handled = key({vim, tf}, ?c, ctrl)
    end

    test "insert mode always returns :not_handled" do
      vim = Vim.new()
      tf = TextField.new("hello")
      assert :not_handled = Vim.handle_key(vim, tf, ?a, 0)
    end

    test "Escape cancels operator-pending" do
      {vim, tf} = normal("hello")
      {:handled, vim, _tf} = key({vim, tf}, ?d)
      assert Vim.mode(vim) == :operator_pending
      {:handled, vim, _tf} = key({vim, tf}, 27)
      assert Vim.mode(vim) == :normal
    end
  end
end
