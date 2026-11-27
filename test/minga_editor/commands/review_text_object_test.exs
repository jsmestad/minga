defmodule MingaEditor.Commands.ReviewTextObjectTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess

  test "Visual ih selects a complete multibyte change, not the context beside it" do
    ctx = start_editor("left OLD right")
    buffer = active_buffer(ctx)
    edit(buffer, {0, 5}, 3, "λ🙂")
    :ok = Buffer.move_to(buffer, {0, 7})

    send_keys_sync(ctx, "vihd")
    assert buffer_content(ctx) == "left  right"
    assert buffer_cursor(ctx) == {0, 5}
  end

  test "the around object includes the touched source line and uses a linewise register" do
    ctx = start_editor("header\nleft old right\nfooter")
    buffer = active_buffer(ctx)
    edit(buffer, {1, 5}, 3, "NEW")
    :ok = Buffer.move_to(buffer, {1, 6})

    send_keys_sync(ctx, "yahp")
    assert buffer_content(ctx) == "header\nleft NEW right\nleft NEW right\nfooter"
  end

  test "an inner operator at a deletion anchor never consumes the surviving next character" do
    ctx = start_editor("header\nleft Xright\nfooter")
    buffer = active_buffer(ctx)
    edit(buffer, {1, 5}, 1, "")
    :ok = Buffer.move_to(buffer, {1, 5})

    send_keys_sync(ctx, "dih")
    assert buffer_content(ctx) == "header\nleft right\nfooter"
    send_keys_sync(ctx, "vahd")
    assert buffer_content(ctx) == "header\nfooter"
  end

  defp edit(buffer, position, size, text) do
    assert {:ok, _receipt} =
             BufferProcess.replace_byte_range_if_version(
               buffer,
               Buffer.version(buffer),
               position,
               size,
               text,
               EditSource.minga("task", "edit")
             )
  end
end
