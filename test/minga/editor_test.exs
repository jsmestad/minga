defmodule Minga.EditorTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  # Helper: start a fresh editor with its own buffer.
  # The editor uses a nil port_manager (send_commands to nil just logs a
  # warning), which is fine for unit tests.
  defp start_editor(content \\ "hello\nworld\nfoo") do
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

  # Helper: send a key and wait for the GenServer to process it.
  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    Process.sleep(30)
  end

  describe "init" do
    test "editor starts alive with Normal mode" do
      {editor, _buffer} = start_editor()
      assert Process.alive?(editor)
    end
  end

  describe "Normal mode — movements" do
    test "l moves cursor right without changing content" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)

      send_key(editor, ?l)
      send_key(editor, ?l)

      assert BufferServer.content(buffer) == original
      assert BufferServer.cursor(buffer) == {0, 2}
    end

    test "h moves cursor left" do
      {editor, buffer} = start_editor("hello")
      # Move right twice then left once
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?h)

      assert BufferServer.cursor(buffer) == {0, 1}
    end

    test "j moves cursor down" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?j)
      assert elem(BufferServer.cursor(buffer), 0) == 1
    end

    test "k moves cursor up after moving down" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?j)
      send_key(editor, ?k)
      assert elem(BufferServer.cursor(buffer), 0) == 0
    end

    test "arrow keys move cursor without changing content" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      original = BufferServer.content(buffer)

      # right arrow (57421) twice
      send_key(editor, 57421)
      send_key(editor, 57421)

      assert BufferServer.content(buffer) == original
      assert BufferServer.cursor(buffer) == {0, 2}
    end

    test "unknown keys in normal mode are ignored" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)

      # 'x' is not bound in our Normal mode yet
      send_key(editor, ?x)

      assert BufferServer.content(buffer) == original
    end
  end

  describe "Normal mode — count prefix" do
    test "3l moves cursor right 3 times" do
      {editor, buffer} = start_editor("hello world")
      send_key(editor, ?3)
      send_key(editor, ?l)
      assert BufferServer.cursor(buffer) == {0, 3}
    end

    test "2j moves cursor down 2 lines" do
      {editor, buffer} = start_editor("a\nb\nc\nd")
      send_key(editor, ?2)
      send_key(editor, ?j)
      assert elem(BufferServer.cursor(buffer), 0) == 2
    end
  end

  describe "Normal → Insert transition" do
    test "i enters insert mode and allows character insertion" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)

      assert BufferServer.content(buffer) == "xhello"
    end

    test "a moves right and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?a)
      send_key(editor, ?x)

      # cursor was at col 0 before 'a'; 'a' moves right to col 1,
      # then 'x' is inserted at col 1
      assert String.contains?(BufferServer.content(buffer), "x")
    end

    test "A moves to line end and enters insert mode" do
      {editor, buffer} = start_editor("hi")
      send_key(editor, ?A)
      send_key(editor, ?!)

      content = BufferServer.content(buffer)
      assert String.contains?(content, "!")
    end

    test "I moves to line start and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      # Move right to avoid being at start already
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?I)
      send_key(editor, ?^)

      content = BufferServer.content(buffer)
      assert String.starts_with?(content, "^")
    end

    test "o inserts a new line below and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?o)
      send_key(editor, ?w)

      content = BufferServer.content(buffer)
      assert String.contains?(content, "\n")
      assert String.contains?(content, "w")
    end

    test "O inserts a new line above and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?O)
      send_key(editor, ?w)

      content = BufferServer.content(buffer)
      assert String.contains?(content, "\n")
      assert String.contains?(content, "w")
    end
  end

  describe "Insert mode operations" do
    test "insert character updates buffer" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?i)
      send_key(editor, ?x)

      assert BufferServer.content(buffer) == "xhello\nworld\nfoo"
    end

    test "backspace (127) deletes character in insert mode" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?i)
      send_key(editor, ?a)
      Process.sleep(20)
      send_key(editor, 127)

      assert BufferServer.content(buffer) == "hello\nworld\nfoo"
    end

    test "enter inserts newline in insert mode" do
      {editor, buffer} = start_editor("hello\nworld\nfoo")
      send_key(editor, ?i)
      send_key(editor, 13)

      assert BufferServer.content(buffer) == "\nhello\nworld\nfoo"
    end
  end

  describe "Insert → Normal transition" do
    test "Escape returns to Normal mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)
      send_key(editor, 27)

      # After Escape, typing 'l' should move cursor (not insert)
      content_before = BufferServer.content(buffer)
      send_key(editor, ?l)
      # Content should not change, only cursor
      assert BufferServer.content(buffer) == content_before
    end
  end

  describe "handle_info — resize" do
    test "resize event updates viewport" do
      {editor, _buffer} = start_editor()
      send(editor, {:minga_input, {:resize, 120, 40}})
      Process.sleep(50)
      assert Process.alive?(editor)
    end
  end

  describe "handle_info — ready" do
    test "ready event updates viewport" do
      {editor, _buffer} = start_editor()
      send(editor, {:minga_input, {:ready, 100, 30}})
      Process.sleep(50)
      assert Process.alive?(editor)
    end
  end

  describe "open_file/2" do
    @tag :tmp_dir
    test "opens a file and renders", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test_open.txt")
      File.write!(path, "opened file content")

      {:ok, editor} =
        Editor.start_link(
          name: :"editor_open_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: nil,
          width: 40,
          height: 10
        )

      assert :ok = Editor.open_file(editor, path)
    end
  end
end
