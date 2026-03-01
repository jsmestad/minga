defmodule Minga.Editor.Commands.OperatorsTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  defp start_editor(content) do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  describe "delete operations" do
    test "delete_at via x in normal mode" do
      {editor, _buffer} = start_editor("hello")
      send_key(editor, ?x)
      assert Process.alive?(editor)
    end

    test "dd deletes the current line" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?d)
      send_key(editor, ?d)

      content = BufferServer.content(buffer)
      refute String.contains?(content, "hello")
      assert String.contains?(content, "world")
    end

    test "yy yanks the current line" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?y)
      send_key(editor, ?y)

      assert BufferServer.content(buffer) == "hello\nworld"

      send_key(editor, ?p)
      assert String.contains?(BufferServer.content(buffer), "hello")
    end
  end
end
