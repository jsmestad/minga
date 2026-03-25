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

    test "2dd deletes two lines and p pastes both back" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc\nddd")

      # 2dd: delete two lines starting from cursor (line 0)
      send_key(editor, ?2)
      send_key(editor, ?d)
      send_key(editor, ?d)

      content = BufferServer.content(buffer)
      refute String.contains?(content, "aaa")
      refute String.contains?(content, "bbb")
      assert String.contains?(content, "ccc")
      assert String.contains?(content, "ddd")

      # p: paste after cursor — should restore both deleted lines
      send_key(editor, ?p)

      pasted = BufferServer.content(buffer)
      assert String.contains?(pasted, "aaa")
      assert String.contains?(pasted, "bbb")
    end

    test "3dd deletes three lines and p pastes all three back" do
      {editor, buffer} = start_editor("line1\nline2\nline3\nline4\nline5")

      send_key(editor, ?3)
      send_key(editor, ?d)
      send_key(editor, ?d)

      content = BufferServer.content(buffer)
      refute String.contains?(content, "line1")
      refute String.contains?(content, "line2")
      refute String.contains?(content, "line3")
      assert String.contains?(content, "line4")

      send_key(editor, ?p)

      pasted = BufferServer.content(buffer)
      assert String.contains?(pasted, "line1")
      assert String.contains?(pasted, "line2")
      assert String.contains?(pasted, "line3")
    end

    test "2yy yanks two lines and p pastes both" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc")

      send_key(editor, ?2)
      send_key(editor, ?y)
      send_key(editor, ?y)

      # Buffer should be unchanged after yank
      assert BufferServer.content(buffer) == "aaa\nbbb\nccc"

      # Move to last line and paste
      send_key(editor, ?G)
      send_key(editor, ?p)

      pasted = BufferServer.content(buffer)
      assert String.contains?(pasted, "aaa")
      assert String.contains?(pasted, "bbb")

      # Both yanked lines should appear in the pasted content
      lines = String.split(pasted, "\n")
      assert length(lines) == 5
    end

    test "cc clears current line and enters insert mode" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?c)
      send_key(editor, ?c)

      # Line should be cleared but still exist
      content = BufferServer.content(buffer)
      refute String.contains?(content, "hello")
      assert String.contains?(content, "world")
      assert String.contains?(content, "foo")

      # The editor should now be in insert mode
      %{workspace: %{vim: %{mode: mode}}} = :sys.get_state(editor)
      assert mode == :insert
    end

    test "2cc deletes both lines and register contains both" do
      {editor, buffer} = start_editor("aaa\nbbb\nccc\nddd")

      send_key(editor, ?2)
      send_key(editor, ?c)
      send_key(editor, ?c)

      content = BufferServer.content(buffer)
      refute String.contains?(content, "aaa")
      refute String.contains?(content, "bbb")
      assert String.contains?(content, "ccc")
      assert String.contains?(content, "ddd")

      # Should be in insert mode
      %{workspace: %{vim: %{mode: mode}}} = :sys.get_state(editor)
      assert mode == :insert

      # Escape to normal, then paste to verify register has both lines
      send_key(editor, 27)
      send_key(editor, ?p)

      pasted = BufferServer.content(buffer)
      assert String.contains?(pasted, "aaa")
      assert String.contains?(pasted, "bbb")
    end

    test "dd on single line clears content" do
      {editor, buffer} = start_editor("only line")
      send_key(editor, ?d)
      send_key(editor, ?d)

      content = BufferServer.content(buffer)
      assert content == ""
    end

    test "2dd with count exceeding buffer lines deletes to end" do
      {editor, buffer} = start_editor("aaa\nbbb")

      # 5dd but only 2 lines exist — should delete both without crashing
      send_key(editor, ?5)
      send_key(editor, ?d)
      send_key(editor, ?d)

      content = BufferServer.content(buffer)
      assert content == ""
    end
  end
end
