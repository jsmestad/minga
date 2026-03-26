defmodule Minga.Editor.Commands.VisualTest do
  use Minga.Test.EditingModelCase, async: true

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
        height: 10,
        editing_model: :vim
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  describe "visual mode" do
    test "v enters visual mode and d deletes selection" do
      {editor, buffer} = start_editor("hello world")
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?d)

      content = BufferServer.content(buffer)
      refute String.starts_with?(content, "hel")
    end

    test "V enters linewise visual mode" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?V)
      send_key(editor, ?j)
      send_key(editor, ?d)

      content = BufferServer.content(buffer)
      assert String.contains?(content, "foo")
    end

    test "v then y yanks visual selection" do
      {editor, buffer} = start_editor("hello world")
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?y)

      assert BufferServer.content(buffer) == "hello world"

      send_key(editor, ?p)
      assert String.length(BufferServer.content(buffer)) > String.length("hello world")
    end
  end
end
