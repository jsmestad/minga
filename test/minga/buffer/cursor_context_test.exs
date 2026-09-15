defmodule Minga.Buffer.CursorContextTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.CursorContext
  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :tmp_dir

  test "returns cursor-local text and metadata in one coherent snapshot", %{tmp_dir: tmp_dir} do
    content = "first\nαe\u0301_value\nlast"
    path = Path.join(tmp_dir, "context.ex")
    File.write!(path, content)
    {:ok, buffer} = BufferProcess.start_link(file_path: path)
    prefix = "αe\u0301_"
    :ok = Buffer.move_to(buffer, {1, byte_size(prefix)})
    :ok = Buffer.insert_text(buffer, "x")

    assert %CursorContext{
             line: 1,
             byte_column: byte_column,
             grapheme_column: 4,
             line_text: "αe\u0301_xvalue",
             line_prefix: "αe\u0301_x",
             version: 1,
             file_path: ^path,
             filetype: :elixir
           } = Buffer.cursor_context(buffer)

    assert byte_column == byte_size("αe\u0301_x")
  end

  test "extracts same-line text by byte position without confusing graphemes and bytes" do
    {:ok, buffer} = BufferProcess.start_link(content: "αe\u0301_value")
    :ok = Buffer.move_to(buffer, {0, byte_size("αe\u0301_val")})
    context = Buffer.cursor_context(buffer)

    assert CursorContext.text_since(context, {0, byte_size("αe\u0301_")}) == "val"
    assert CursorContext.text_since(context, {1, 0}) == nil
    assert CursorContext.text_since(context, {0, context.byte_column + 1}) == nil
  end
end
