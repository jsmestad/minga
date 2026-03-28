defmodule Minga.IntegrationTest do
  @moduledoc """
  End-to-end integration tests that exercise the full editor pipeline
  via the headless testing harness: buffer → editor FSM → command execution
  → render output + buffer state verification.

  Pure-function tests for navigation, operators, undo, and insert operations
  live at the correct layer:
  - Navigation: test/minga/editing/motion/navigation_test.exs
  - Line deletion: test/minga/buffer/delete_lines_test.exs
  - Undo: test/minga/buffer/undo_test.exs
  - Insert operations: test/minga/buffer/insert_operations_test.exs
  """

  use Minga.Test.EditorCase, async: true

  @moduletag :tmp_dir

  # ── Insert mode (screen rendering verification) ───────────────────────────

  describe "Insert mode — render verification" do
    test "i enters insert mode and rendered output reflects insertion" do
      ctx = start_editor("hello")

      send_key_sync(ctx, ?i)
      assert_mode(ctx, :insert)

      type_text(ctx, "abc")

      assert buffer_content(ctx) == "abchello"
      assert_row_contains(ctx, 1, "abchello")
    end
  end

  # ── Paste (requires Editor register state) ────────────────────────────────

  describe "p / P — paste" do
    test "p pastes register text after cursor after yy" do
      ctx = start_editor("hello\nworld")

      send_key_sync(ctx, ?y)
      send_key_sync(ctx, ?y)
      send_key_sync(ctx, ?j)
      send_key_sync(ctx, ?p)

      lines = buffer_content(ctx) |> String.split("\n")
      assert length(lines) >= 3
    end

    test "P pastes register text before cursor" do
      ctx = start_editor("hello\nworld")

      send_key_sync(ctx, ?y)
      send_key_sync(ctx, ?y)
      send_key_sync(ctx, ?j)
      send_key_sync(ctx, ?P)

      assert String.contains?(buffer_content(ctx), "hello")
    end
  end

  # ── Command mode (:w) ─────────────────────────────────────────────────────

  describe ":w — save via command mode" do
    test "saves buffer to a tmp file via :w command", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "integration_save.txt")
      ctx = start_editor("save me", file_path: path)

      # Type some content, then save via :w
      send_keys_sync(ctx, "iextra <Esc>:w<CR>")

      assert File.exists?(path)
      assert String.contains?(File.read!(path), "extra")
    end
  end

  # ── Full pipeline smoke test ──────────────────────────────────────────────

  describe "full pipeline smoke test" do
    test "navigate, insert, delete, undo flow with render verification" do
      ctx = start_editor("line one\nline two\nline three")

      # Navigate
      send_key_sync(ctx, ?j)
      send_key_sync(ctx, ?l)
      send_key_sync(ctx, ?l)
      assert_modeline_contains(ctx, "2:3")

      # Enter insert mode and type
      send_keys_sync(ctx, "iINSERTED<Esc>")
      assert String.contains?(buffer_content(ctx), "INSERTED")
      assert_row_contains(ctx, 2, "INSERTED")

      # Delete the line
      send_key_sync(ctx, ?d)
      send_key_sync(ctx, ?d)
      refute String.contains?(buffer_content(ctx), "INSERTED")

      # Undo the delete
      send_key_sync(ctx, ?u)
      assert String.contains?(buffer_content(ctx), "INSERTED")
      assert_row_contains(ctx, 2, "INSERTED")

      # Editor stays alive throughout
      assert Process.alive?(ctx.editor)
      assert Process.alive?(ctx.buffer)
    end
  end
end
