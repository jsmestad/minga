defmodule MingaEditor.ShiftLinesKeysTest do
  @moduledoc "Actual-path smoke for multiline `>` and `<` through key dispatch (#3499)."

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer.Process, as: BufferProcess

  setup do
    ctx = start_editor("a\nb\nc\nd\ne")
    BufferProcess.set_option(ctx.buffer, :indent_with, :spaces)
    BufferProcess.set_option(ctx.buffer, :tab_width, 2)
    %{ctx: ctx}
  end

  test "a counted >> shifts the counted lines, dot repeats it, and each undo reverts one shift",
       %{
         ctx: ctx
       } do
    send_keys_sync(ctx, "3>>")
    assert buffer_content(ctx) == "  a\n  b\n  c\nd\ne"

    send_keys_sync(ctx, "jj.")
    assert buffer_content(ctx) == "  a\n  b\n    c\n  d\n  e"

    send_keys_sync(ctx, "u")
    assert buffer_content(ctx) == "  a\n  b\n  c\nd\ne"

    send_keys_sync(ctx, "u")
    assert buffer_content(ctx) == "a\nb\nc\nd\ne"
  end

  test "a visual line selection shifts right and back left", %{ctx: ctx} do
    send_keys_sync(ctx, "jVj>")
    assert buffer_content(ctx) == "a\n  b\n  c\nd\ne"

    send_keys_sync(ctx, "ggjVj<")
    assert buffer_content(ctx) == "a\nb\nc\nd\ne"
  end
end
