defmodule Minga.Integration.ModeTransitionsTest do
  @moduledoc """
  Integration tests for mode transitions.

  Verifies that every mode transition produces the correct screen state:
  cursor position, cursor shape, modeline badge, minibuffer content, and
  focus location. These tests exercise the full pipeline from key input
  through the editor GenServer to the rendered HeadlessPort output.
  """

  use Minga.Test.EditorCase, async: true

  # ── Normal → Insert ──────────────────────────────────────────────────────────

  describe "normal → insert (i)" do
    test "modeline shows INSERT, cursor shape is beam" do
      ctx = start_editor("hello world")

      send_keys(ctx, "i")

      assert_modeline_contains(ctx, "INSERT")
      assert cursor_shape(ctx) == :beam
      assert editor_mode(ctx) == :insert
      assert_screen_snapshot(ctx, "normal_to_insert_i")
    end
  end

  describe "normal → insert (a)" do
    test "cursor moves right one column, enters insert mode" do
      ctx = start_editor("hello world")

      send_keys(ctx, "a")

      assert cursor_shape(ctx) == :beam
      assert_modeline_contains(ctx, "INSERT")
      assert_screen_snapshot(ctx, "normal_to_insert_a")
    end
  end

  describe "normal → insert (A)" do
    test "cursor moves to end of line, enters insert mode" do
      ctx = start_editor("hello world")

      send_keys(ctx, "A")

      assert cursor_shape(ctx) == :beam
      assert_modeline_contains(ctx, "INSERT")
      assert_screen_snapshot(ctx, "normal_to_insert_shift_a")
    end
  end

  describe "normal → insert (o)" do
    test "opens new line below, cursor on new line" do
      ctx = start_editor("hello\nworld")

      send_keys(ctx, "o")

      assert cursor_shape(ctx) == :beam
      assert_modeline_contains(ctx, "INSERT")
      {line, _col} = buffer_cursor(ctx)
      assert line == 1
      assert_screen_snapshot(ctx, "normal_to_insert_o")
    end
  end

  describe "normal → insert (O)" do
    test "opens new line above, cursor on new line" do
      ctx = start_editor("hello\nworld")

      send_keys(ctx, "O")

      assert cursor_shape(ctx) == :beam
      assert_modeline_contains(ctx, "INSERT")
      {line, _col} = buffer_cursor(ctx)
      assert line == 0
      assert_screen_snapshot(ctx, "normal_to_insert_shift_o")
    end
  end

  # ── Insert → Normal ──────────────────────────────────────────────────────────

  describe "insert → normal (Escape)" do
    test "cursor shape returns to block, modeline shows NORMAL" do
      ctx = start_editor("hello world")

      send_keys(ctx, "i")
      assert cursor_shape(ctx) == :beam

      send_keys(ctx, "<Esc>")

      assert cursor_shape(ctx) == :block
      assert_modeline_contains(ctx, "NORMAL")
      assert editor_mode(ctx) == :normal
      assert_screen_snapshot(ctx, "insert_to_normal_escape")
    end

    test "cursor stays at same column on escape" do
      ctx = start_editor("hello world")

      # Move right three times then enter insert mode
      send_keys(ctx, "llli")
      assert editor_mode(ctx) == :insert
      {_, col_in_insert} = buffer_cursor(ctx)

      send_keys(ctx, "<Esc>")

      {_, col_after_escape} = buffer_cursor(ctx)
      # Minga currently keeps cursor at same column on insert→normal
      assert col_after_escape == col_in_insert
    end

    test "cursor stays at col 0 when escaping at start of line" do
      ctx = start_editor("hello world")

      send_keys(ctx, "i<Esc>")

      {_line, col} = buffer_cursor(ctx)
      assert col == 0
    end
  end

  # ── Normal → Visual ──────────────────────────────────────────────────────────

  describe "normal → visual (v)" do
    test "modeline shows VISUAL, cursor stays block" do
      ctx = start_editor("hello world")

      send_keys(ctx, "v")

      assert_modeline_contains(ctx, "VISUAL")
      assert cursor_shape(ctx) == :block
      assert editor_mode(ctx) == :visual
      assert_screen_snapshot(ctx, "normal_to_visual_v")
    end
  end

  describe "normal → visual line (V)" do
    test "modeline shows V-LINE" do
      ctx = start_editor("hello world\nsecond line")

      send_keys(ctx, "V")

      assert_modeline_contains(ctx, "V-LINE")
      assert cursor_shape(ctx) == :block
      assert_screen_snapshot(ctx, "normal_to_visual_line_shift_v")
    end
  end

  # ── Visual → Normal ──────────────────────────────────────────────────────────

  describe "visual → normal (Escape)" do
    test "returns to normal mode, selection cleared" do
      ctx = start_editor("hello world\nsecond line")

      send_keys(ctx, "vlll")
      assert_modeline_contains(ctx, "VISUAL")

      send_keys(ctx, "<Esc>")

      assert_modeline_contains(ctx, "NORMAL")
      assert cursor_shape(ctx) == :block
      assert editor_mode(ctx) == :normal
      assert_screen_snapshot(ctx, "visual_to_normal_escape")
    end
  end

  # ── Normal → Command ──────────────────────────────────────────────────────────

  describe "normal → command (:)" do
    test "minibuffer shows colon, cursor moves to minibuffer row" do
      ctx = start_editor("hello world")

      send_keys(ctx, ":")

      assert_minibuffer_contains(ctx, ":")
      assert_modeline_contains(ctx, "COMMAND")
      assert cursor_shape(ctx) == :beam
      assert editor_mode(ctx) == :command

      # Cursor should be on the minibuffer row (last row)
      {cursor_row, _cursor_col} = screen_cursor(ctx)
      assert cursor_row == ctx.height - 1

      assert_screen_snapshot(ctx, "normal_to_command")
    end
  end

  # ── Command → Normal ──────────────────────────────────────────────────────────

  describe "command → normal (Escape)" do
    test "minibuffer clears, cursor returns to buffer, modeline shows NORMAL" do
      ctx = start_editor("hello world")

      # Record cursor position before command mode
      cursor_before = screen_cursor(ctx)

      send_keys(ctx, ":")
      assert_modeline_contains(ctx, "COMMAND")

      send_keys(ctx, "<Esc>")

      assert_modeline_contains(ctx, "NORMAL")
      assert cursor_shape(ctx) == :block
      assert editor_mode(ctx) == :normal

      # Cursor should return to where it was before command mode
      cursor_after = screen_cursor(ctx)
      assert cursor_after == cursor_before

      # Minibuffer should be empty
      mb = minibuffer(ctx)
      refute String.contains?(mb, ":")

      assert_screen_snapshot(ctx, "command_to_normal_escape")
    end
  end

  describe "command → normal (Enter with valid command)" do
    test "executes command and returns to normal mode" do
      ctx = start_editor("hello world")

      # :set nu is a valid command that toggles line numbers
      send_keys(ctx, ":set nu<CR>")

      assert_modeline_contains(ctx, "NORMAL")
      assert cursor_shape(ctx) == :block
      assert editor_mode(ctx) == :normal
      assert_screen_snapshot(ctx, "command_execute_set_nu")
    end
  end

  describe "command → normal (Backspace to empty)" do
    test "backspacing past empty input exits command mode" do
      ctx = start_editor("hello world")

      cursor_before = screen_cursor(ctx)

      send_keys(ctx, ":x<BS><BS>")

      assert_modeline_contains(ctx, "NORMAL")
      assert cursor_shape(ctx) == :block
      assert editor_mode(ctx) == :normal

      cursor_after = screen_cursor(ctx)
      assert cursor_after == cursor_before
    end
  end

  # ── Normal → Operator Pending ──────────────────────────────────────────────

  describe "normal → operator pending (d)" do
    test "modeline stays NORMAL while in operator-pending mode" do
      ctx = start_editor("hello world\nsecond line")

      send_keys(ctx, "d")

      # Operator-pending is an invisible sub-state of Normal (like Vim/Doom).
      # The modeline should NOT flash "OPERATOR".
      assert_modeline_contains(ctx, "NORMAL")
      assert editor_mode(ctx) == :operator_pending
      assert_screen_snapshot(ctx, "normal_to_operator_d")
    end
  end

  describe "operator pending → normal (Escape)" do
    test "cancels operator, returns to normal with no changes" do
      ctx = start_editor("hello world\nsecond line")

      content_before = buffer_content(ctx)

      send_keys(ctx, "d<Esc>")

      assert_modeline_contains(ctx, "NORMAL")
      assert editor_mode(ctx) == :normal
      assert buffer_content(ctx) == content_before
      assert_screen_snapshot(ctx, "operator_pending_cancel")
    end
  end

  describe "operator pending → normal (dd completes)" do
    test "executes linewise delete, returns to normal" do
      ctx = start_editor("first\nsecond\nthird")

      send_keys(ctx, "dd")

      assert_modeline_contains(ctx, "NORMAL")
      assert editor_mode(ctx) == :normal
      refute String.contains?(buffer_content(ctx), "first")
      assert_screen_snapshot(ctx, "operator_dd_complete")
    end
  end

  # ── Normal → Replace ──────────────────────────────────────────────────────────

  describe "normal → replace (r)" do
    test "r awaits replacement char, stays in normal mode" do
      ctx = start_editor("hello world")

      # r sets pending_replace in normal mode state, not a mode transition
      send_keys(ctx, "r")

      assert_modeline_contains(ctx, "NORMAL")
      assert editor_mode(ctx) == :normal
      assert_screen_snapshot(ctx, "normal_pending_replace_r")
    end
  end

  describe "replace char completes (rX)" do
    test "replaces character and stays in normal mode" do
      ctx = start_editor("hello world")

      send_keys(ctx, "rX")

      assert_modeline_contains(ctx, "NORMAL")
      assert cursor_shape(ctx) == :block
      assert String.starts_with?(buffer_content(ctx), "Xello")
      assert_screen_snapshot(ctx, "replace_char_complete")
    end
  end

  # ── Multi-step transitions ──────────────────────────────────────────────────

  describe "multi-step: normal → insert → normal → command → normal" do
    test "all transitions produce correct screen state" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      # Step 1: Enter insert mode, type text
      send_keys(ctx, "iABC<Esc>")
      assert_modeline_contains(ctx, "NORMAL")
      assert cursor_shape(ctx) == :block
      assert String.contains?(buffer_content(ctx), "ABC")

      # Step 2: Enter command mode
      send_keys(ctx, ":")
      assert_modeline_contains(ctx, "COMMAND")
      assert cursor_shape(ctx) == :beam
      {cursor_row, _} = screen_cursor(ctx)
      assert cursor_row == ctx.height - 1

      # Step 3: Escape back to normal
      send_keys(ctx, "<Esc>")
      assert_modeline_contains(ctx, "NORMAL")
      assert cursor_shape(ctx) == :block

      # Content should still have our insertion
      assert String.contains?(buffer_content(ctx), "ABC")

      assert_screen_snapshot(ctx, "multi_step_ins_cmd_normal")
    end
  end

  describe "multi-step: normal → visual → operator (c) → insert → normal" do
    test "visual change enters insert mode then returns to normal" do
      ctx = start_editor("hello world")

      # Select "hel" in visual mode, then change
      send_keys(ctx, "vllc")
      assert_modeline_contains(ctx, "INSERT")
      assert cursor_shape(ctx) == :beam

      # Type replacement text
      type_text(ctx, "XYZ")

      # Escape back to normal
      send_keys(ctx, "<Esc>")
      assert_modeline_contains(ctx, "NORMAL")
      assert cursor_shape(ctx) == :block
      assert String.starts_with?(buffer_content(ctx), "XYZ")

      assert_screen_snapshot(ctx, "multi_step_visual_change")
    end
  end

  # ── Search mode ─────────────────────────────────────────────────────────────

  describe "normal → search (/)" do
    test "minibuffer shows search prompt, cursor on minibuffer row" do
      ctx = start_editor("hello world\nfoo bar")

      send_keys(ctx, "/")

      assert_modeline_contains(ctx, "SEARCH")
      assert cursor_shape(ctx) == :beam
      {cursor_row, _} = screen_cursor(ctx)
      assert cursor_row == ctx.height - 1
      assert_screen_snapshot(ctx, "normal_to_search")
    end
  end

  describe "search → normal (Escape)" do
    test "cancels search, returns cursor to original position" do
      ctx = start_editor("hello world\nfoo bar")

      cursor_before = screen_cursor(ctx)

      send_keys(ctx, "/hello<Esc>")

      assert_modeline_contains(ctx, "NORMAL")
      assert cursor_shape(ctx) == :block
      cursor_after = screen_cursor(ctx)
      assert cursor_after == cursor_before
      assert_screen_snapshot(ctx, "search_to_normal_escape")
    end
  end
end
