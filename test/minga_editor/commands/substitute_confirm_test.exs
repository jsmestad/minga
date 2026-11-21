defmodule MingaEditor.Commands.SubstituteConfirmTest do
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Editing
  alias MingaEditor.MinibufferData
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  test "non-global offers keep their term order and restore the first offered line after an edit" do
    content = "  foo foo\nfoo foo"
    ctx = start_editor(content)

    assert_offer(ctx, send_ex_sync(ctx, "%s/foo/bar/c"), {1, 0}, "1 of 2")
    assert_offer(ctx, send_keys_sync(ctx, "n"), {0, 2}, "2 of 2")
    assert buffer_content(ctx) == content

    state = send_keys_sync(ctx, "y")
    assert Editing.mode(state) == :normal
    assert buffer_content(ctx) == "  bar foo\nfoo foo"
    assert buffer_cursor(ctx) == {1, 0}
    assert NoticeWorkflow.message(state) == "1 substitution"
  end

  test "global offers advance in discovery order and commit n, y, a decisions only on exit" do
    content = "  foo foo\nfoo foo"
    ctx = start_editor(content)

    assert_offer(ctx, send_ex_sync(ctx, "%s/foo/bar/gc"), {0, 2}, "1 of 4")
    assert_offer(ctx, send_keys_sync(ctx, "n"), {0, 6}, "2 of 4")
    assert_offer(ctx, send_keys_sync(ctx, "y"), {1, 0}, "3 of 4")
    assert buffer_content(ctx) == content

    state = send_keys_sync(ctx, "a")
    assert Editing.mode(state) == :normal
    assert buffer_content(ctx) == "  foo bar\nbar bar"
    assert buffer_cursor(ctx) == {0, 0}
    assert NoticeWorkflow.message(state) == "3 of 4 substitutions"
  end

  test "accepting overlapping matches edits the changed bytes in reverse offered order" do
    ctx = start_editor("aaa")
    assert_offer(ctx, send_ex_sync(ctx, "%s/aa/XY/gc"), {0, 0}, "1 of 2", "XY")

    state = send_keys_sync(ctx, "a")
    assert Editing.mode(state) == :normal
    assert buffer_content(ctx) == "XYY"
    assert buffer_cursor(ctx) == {0, 0}
    assert NoticeWorkflow.message(state) == "2 of 2 substitutions"
  end

  for {name, key} <- [{"q", "q"}, {"Escape", "<Esc>"}] do
    test "#{name} applies earlier accepts but leaves the current offer unchanged" do
      content = "foo\n  foo"
      ctx = start_editor(content)
      assert_offer(ctx, send_ex_sync(ctx, "%s/foo/bar/gc"), {0, 0}, "1 of 2")
      assert_offer(ctx, send_keys_sync(ctx, "y"), {1, 2}, "2 of 2")
      assert buffer_content(ctx) == content

      state = send_keys_sync(ctx, unquote(key))
      assert Editing.mode(state) == :normal
      assert buffer_content(ctx) == "bar\n  foo"
      assert buffer_cursor(ctx) == {0, 0}
      assert NoticeWorkflow.message(state) == "1 substitution"
    end
  end

  test "y on one offer applies immediately and restores the first offered line" do
    ctx = start_editor("  foo")
    assert_offer(ctx, send_ex_sync(ctx, "%s/foo/bar/c"), {0, 2}, "1 of 1")

    state = send_keys_sync(ctx, "y")
    assert Editing.mode(state) == :normal
    assert buffer_content(ctx) == "  bar"
    assert buffer_cursor(ctx) == {0, 0}
    assert NoticeWorkflow.message(state) == "1 substitution"
  end

  test "n on one offer exits without a content replacement or cursor restore" do
    ctx = start_editor("  foo")
    version = Buffer.version(ctx.buffer)
    assert_offer(ctx, send_ex_sync(ctx, "%s/foo/bar/c"), {0, 2}, "1 of 1")

    state = send_keys_sync(ctx, "n")
    assert Editing.mode(state) == :normal
    assert buffer_content(ctx) == "  foo"
    assert Buffer.version(ctx.buffer) == version
    assert buffer_cursor(ctx) == {0, 2}
    assert NoticeWorkflow.message(state) == "No substitutions made"
  end

  test "no matches leaves the editor in normal mode with a pattern-not-found notice" do
    ctx = start_editor("foo")
    send_keys_sync(ctx, "l")

    state = send_ex_sync(ctx, "%s/baz/bar/gc")
    assert Editing.mode(state) == :normal
    assert buffer_content(ctx) == "foo"
    assert buffer_cursor(ctx) == {0, 1}
    assert NoticeWorkflow.message(state) == "Pattern not found: baz"
  end

  test "a failed backward search can be repeated without first moving the cursor" do
    ctx = start_editor("empty")
    send_keys_sync(ctx, "l")

    state = send_keys_sync(ctx, "?missing<CR>")
    assert NoticeWorkflow.message(state) == "Pattern not found: missing"
    assert buffer_cursor(ctx) == {0, 1}

    assert :ok = Buffer.replace_content(ctx.buffer, "missing middle missing")
    assert :ok = Buffer.move_to(ctx.buffer, {0, 8})
    send_keys_sync(ctx, "n")
    assert buffer_cursor(ctx) == {0, 0}
  end

  test "substitution records its pattern without changing the repeat direction" do
    ctx = start_editor("foo foo mid foo")
    send_keys_sync(ctx, "?mid<CR>")
    send_ex_sync(ctx, "%s/foo/bar")
    assert buffer_content(ctx) == "bar foo mid foo"

    assert :ok = Buffer.move_to(ctx.buffer, {0, 8})
    send_keys_sync(ctx, "n")
    assert buffer_cursor(ctx) == {0, 4}
  end

  defp assert_offer(ctx, state, position, progress, replacement \\ "bar") do
    assert Editing.mode(state) == :substitute_confirm
    assert buffer_cursor(ctx) == position
    assert NoticeWorkflow.message(state) == nil

    minibuffer = MinibufferData.from_state(state)
    assert minibuffer.prompt == "replace with #{replacement}?"
    assert minibuffer.context == "y/n/a/q (#{progress})"
  end
end
