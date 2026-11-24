defmodule MingaEditor.Commands.JumpListKeysTest do
  @moduledoc """
  Wiring for the keys docs/design/keys.md moved: ⌃O / ⌃I (and Tab) walk the jump list across buffers, and `SPC ;` opens eval.

  The list's rules are covered by `MingaEditor.JumpListTest`; these tests prove the keys reach it through the real input path.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :tmp_dir

  @content Enum.map_join(0..29, "\n", &"line #{&1}")

  test "⌃O returns to where G started and ⌃I goes forward again" do
    ctx = start_editor(@content)
    send_keys_sync(ctx, "5j")
    assert buffer_cursor(ctx) == {5, 0}

    send_keys_sync(ctx, "G")
    assert {29, _} = buffer_cursor(ctx)

    send_keys_sync(ctx, "<C-o>")
    assert buffer_cursor(ctx) == {5, 0}

    send_keys_sync(ctx, "<C-i>")
    assert {29, _} = buffer_cursor(ctx)
  end

  test "Tab is ⌃I in Normal mode, as terminals send it" do
    ctx = start_editor(@content)
    send_keys_sync(ctx, "gg")
    send_keys_sync(ctx, "G")
    send_keys_sync(ctx, "<C-o>")
    assert {0, _} = buffer_cursor(ctx)

    send_key_sync(ctx, 9)
    assert {29, _} = buffer_cursor(ctx)
  end

  test "a confirmed search records where the search began" do
    ctx = start_editor(@content)
    send_keys_sync(ctx, "3j")
    send_keys_sync(ctx, "/line 20<CR>")
    assert {20, _} = buffer_cursor(ctx)

    send_keys_sync(ctx, "<C-o>")
    assert buffer_cursor(ctx) == {3, 0}
  end

  test "moving within a line is not a jump" do
    ctx = start_editor(@content)
    send_keys_sync(ctx, "<C-o>")
    assert buffer_cursor(ctx) == {0, 0}
  end

  test "⌃O and ⌃I cross buffers", %{tmp_dir: dir} do
    other = Path.join(dir, "other.txt")
    File.write!(other, "other 0\nother 1\nother 2\n")

    ctx = start_editor(@content)
    send_keys_sync(ctx, "G")
    send_ex_sync(ctx, "e #{other}")
    other_buffer = editor_state(ctx).workspace.buffers.active
    refute other_buffer == ctx.buffer

    send_keys_sync(ctx, "<C-o>")
    assert editor_state(ctx).workspace.buffers.active == ctx.buffer
    assert {29, _} = buffer_cursor(ctx)

    send_keys_sync(ctx, "<C-o>")
    assert editor_state(ctx).workspace.buffers.active == ctx.buffer
    assert buffer_cursor(ctx) == {0, 0}

    send_keys_sync(ctx, "<C-i>")
    send_keys_sync(ctx, "<C-i>")
    assert editor_state(ctx).workspace.buffers.active == other_buffer
  end

  test "previewing buffers in a picker adds no jumps; the confirmed pick is one jump", %{
    tmp_dir: dir
  } do
    paths =
      for name <- ~w(b c d) do
        path = Path.join(dir, "#{name}.txt")
        File.write!(path, "#{name} 0\n#{name} 1\n#{name} 2\n")
        path
      end

    ctx = start_editor(@content)
    Enum.each(paths, &send_ex_sync(ctx, "e #{&1}"))
    origin = editor_state(ctx).workspace.buffers.active
    send_keys_sync(ctx, "2j")

    send_keys_sync(ctx, "<Space>bb")
    send_keys_sync(ctx, "<C-j><C-j>")
    send_keys_sync(ctx, "<CR>")
    picked = editor_state(ctx).workspace.buffers.active
    refute picked == origin

    # The list holds the three :e jumps and the pick, in order; the previewed buffers added nothing.
    {entries, _index} =
      MingaEditor.JumpList.entries(editor_state(ctx).workspace.editing.jump_list)

    [b, c, d] = paths

    assert Enum.map(entries, fn {buffer, {line, _col}} ->
             {BufferProcess.file_path(buffer), line}
           end) ==
             [{nil, 0}, {b, 0}, {c, 0}, {d, 2}]

    send_keys_sync(ctx, "<C-o>")
    assert editor_state(ctx).workspace.buffers.active == origin
    assert {2, 0} = BufferProcess.cursor(origin)
  end

  test "SPC ; opens the eval prompt" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "<Space>;")
    assert editor_mode(ctx) == :eval
  end
end
