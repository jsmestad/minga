defmodule Minga.IntegrationTest do
  @moduledoc """
  End-to-end integration tests that exercise the full editor pipeline
  via the headless testing harness: buffer → editor FSM → command execution
  → render output + buffer state verification.
  """

  use Minga.Test.EditorCase, async: true

  @moduletag :tmp_dir

  # ── Normal mode navigation ────────────────────────────────────────────────────

  describe "Normal mode — hjkl navigation" do
    test "l moves cursor right, content unchanged" do
      ctx = start_editor("hello\nworld\nfoo")
      original = buffer_content(ctx)

      send_key(ctx, ?l)
      send_key(ctx, ?l)

      assert buffer_content(ctx) == original
      assert buffer_cursor(ctx) == {0, 2}
      # Screen cursor is offset by gutter width (3 for a 3-line file)
      assert screen_cursor(ctx) == {0, 3 + 2}
    end

    test "h moves cursor left" do
      ctx = start_editor("hello\nworld\nfoo")

      send_key(ctx, ?l)
      send_key(ctx, ?l)
      send_key(ctx, ?h)

      assert buffer_cursor(ctx) == {0, 1}
    end

    test "j moves cursor down, k moves cursor up" do
      ctx = start_editor("hello\nworld\nfoo")

      send_key(ctx, ?j)
      assert elem(buffer_cursor(ctx), 0) == 1
      assert_modeline_contains(ctx, "2:")

      send_key(ctx, ?k)
      assert elem(buffer_cursor(ctx), 0) == 0
      assert_modeline_contains(ctx, "1:")
    end

    test "multiple l moves advance the column" do
      ctx = start_editor("hello world")

      send_key(ctx, ?l)
      send_key(ctx, ?l)
      send_key(ctx, ?l)

      {_line, col} = buffer_cursor(ctx)
      assert col == 3
    end

    test "0 moves to beginning of line" do
      ctx = start_editor("hello\nworld")

      send_key(ctx, ?l)
      send_key(ctx, ?l)
      send_key(ctx, ?0)

      assert buffer_cursor(ctx) == {0, 0}
    end
  end

  # ── Insert mode ───────────────────────────────────────────────────────────────

  describe "Insert mode — typing and escaping" do
    test "i enters insert mode and characters are inserted" do
      ctx = start_editor("hello")

      send_key(ctx, ?i)
      assert_mode(ctx, :insert)

      type_text(ctx, "abc")

      assert buffer_content(ctx) == "abchello"
      assert_row_contains(ctx, 0, "abchello")
    end

    test "Escape returns to normal mode — subsequent keys move, not insert" do
      ctx = start_editor("hello")

      send_keys(ctx, "ix<Esc>")

      content_after_insert = buffer_content(ctx)
      assert_mode(ctx, :normal)

      send_key(ctx, ?l)
      assert buffer_content(ctx) == content_after_insert
    end

    test "backspace deletes the previous character in insert mode" do
      ctx = start_editor("hello")

      send_keys(ctx, "ia<BS>")

      assert buffer_content(ctx) == "hello"
    end

    test "Enter inserts a newline in insert mode" do
      ctx = start_editor("hello")

      send_keys(ctx, "i<CR>")

      assert String.contains?(buffer_content(ctx), "\n")
    end

    test "a moves right before entering insert mode" do
      ctx = start_editor("hi")

      send_key(ctx, ?a)
      type_text(ctx, "!")

      assert String.contains?(buffer_content(ctx), "!")
    end
  end

  # ── Delete operations ─────────────────────────────────────────────────────────

  describe "dd — delete current line" do
    test "dd deletes the current line and moves cursor" do
      ctx = start_editor("hello\nworld\nfoo")

      send_key(ctx, ?d)
      send_key(ctx, ?d)

      content = buffer_content(ctx)
      refute String.contains?(content, "hello")
      assert String.contains?(content, "world")
    end

    test "dd on a single-line buffer leaves it empty or minimal" do
      ctx = start_editor("only line")

      send_key(ctx, ?d)
      send_key(ctx, ?d)

      refute String.contains?(buffer_content(ctx), "only")
    end
  end

  # ── Undo ──────────────────────────────────────────────────────────────────────

  describe "u — undo" do
    test "u after inserting reverts the buffer" do
      ctx = start_editor("hello")

      send_keys(ctx, "ix<Esc>")
      assert buffer_content(ctx) == "xhello"

      send_key(ctx, ?u)
      assert buffer_content(ctx) == "hello"
    end

    test "u after dd reverts the deletion" do
      ctx = start_editor("hello\nworld\nfoo")

      send_key(ctx, ?d)
      send_key(ctx, ?d)
      refute String.contains?(buffer_content(ctx), "hello")

      send_key(ctx, ?u)
      assert String.contains?(buffer_content(ctx), "hello")
    end

    test "u on unchanged buffer is a no-op" do
      ctx = start_editor("hello")
      original = buffer_content(ctx)

      send_key(ctx, ?u)
      assert buffer_content(ctx) == original
    end

    test "multiple undo steps revert in order" do
      ctx = start_editor("hello")

      send_keys(ctx, "iab<Esc>")
      assert buffer_content(ctx) == "abhello"

      send_key(ctx, ?u)
      after_one_undo = buffer_content(ctx)

      send_key(ctx, ?u)
      after_two_undo = buffer_content(ctx)

      assert String.length(after_one_undo) < String.length("abhello")
      assert String.length(after_two_undo) < String.length(after_one_undo)
    end
  end

  # ── Paste ─────────────────────────────────────────────────────────────────────

  describe "p / P — paste" do
    test "p pastes register text after cursor after yy" do
      ctx = start_editor("hello\nworld")

      send_key(ctx, ?y)
      send_key(ctx, ?y)
      send_key(ctx, ?j)
      send_key(ctx, ?p)

      lines = buffer_content(ctx) |> String.split("\n")
      assert length(lines) >= 3
    end

    test "P pastes register text before cursor" do
      ctx = start_editor("hello\nworld")

      send_key(ctx, ?y)
      send_key(ctx, ?y)
      send_key(ctx, ?j)
      send_key(ctx, ?P)

      assert String.contains?(buffer_content(ctx), "hello")
    end

    test "p is a no-op when register is empty" do
      ctx = start_editor("hello")
      original = buffer_content(ctx)

      send_key(ctx, ?p)
      assert buffer_content(ctx) == original
    end
  end

  # ── Command mode (:w) ─────────────────────────────────────────────────────────

  describe ":w — save via command mode" do
    test "saves buffer to a tmp file via :w command", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "integration_save.txt")
      ctx = start_editor("save me", file_path: path)

      # Type some content, then save via :w
      send_keys(ctx, "iextra <Esc>:w<CR>")

      # Wait for the file system write
      Process.sleep(50)

      assert File.exists?(path)
      assert String.contains?(File.read!(path), "extra")
    end
  end

  # ── Full pipeline smoke test ──────────────────────────────────────────────────

  describe "full pipeline smoke test" do
    test "navigate, insert, delete, undo flow with render verification" do
      ctx = start_editor("line one\nline two\nline three")

      # Navigate
      send_key(ctx, ?j)
      send_key(ctx, ?l)
      send_key(ctx, ?l)
      assert_modeline_contains(ctx, "2:3")

      # Enter insert mode and type
      send_keys(ctx, "iINSERTED<Esc>")
      assert String.contains?(buffer_content(ctx), "INSERTED")
      assert_row_contains(ctx, 1, "INSERTED")

      # Delete the line
      send_key(ctx, ?d)
      send_key(ctx, ?d)
      refute String.contains?(buffer_content(ctx), "INSERTED")

      # Undo the delete
      send_key(ctx, ?u)
      assert String.contains?(buffer_content(ctx), "INSERTED")
      assert_row_contains(ctx, 1, "INSERTED")

      # Editor stays alive throughout
      assert Process.alive?(ctx.editor)
      assert Process.alive?(ctx.buffer)
    end
  end
end
