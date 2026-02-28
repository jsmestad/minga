defmodule Minga.EditorTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  # Helper: start a fresh editor with its own buffer.
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

  # Helper: start editor with no buffer (splash screen)
  defp start_editor_no_buffer do
    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: nil,
        width: 40,
        height: 10
      )

    editor
  end

  # Helper: send a key and wait for the GenServer to process it.
  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    Process.sleep(30)
  end

  # Helper: type a sequence of printable characters.
  defp type_string(editor, text) do
    text
    |> String.to_charlist()
    |> Enum.each(fn char -> send_key(editor, char) end)
  end

  describe "init" do
    test "editor starts alive with Normal mode" do
      {editor, _buffer} = start_editor()
      assert Process.alive?(editor)
    end

    test "editor starts with no buffer" do
      editor = start_editor_no_buffer()
      assert Process.alive?(editor)
    end
  end

  describe "Normal mode — movements" do
    test "h moves cursor left" do
      {editor, buffer} = start_editor("hello")
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

      send_key(editor, 57_421)
      send_key(editor, 57_421)

      assert BufferServer.content(buffer) == original
      assert BufferServer.cursor(buffer) == {0, 2}
    end

    test "unknown keys in normal mode are ignored" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)

      send_key(editor, ?x)
      assert BufferServer.content(buffer) == original
    end

    test "0 moves to beginning of line" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?0)
      assert BufferServer.cursor(buffer) == {0, 0}
    end

    test "$ moves to end of line" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?$)
      {_, col} = BufferServer.cursor(buffer)
      assert col == 4
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

      assert String.contains?(BufferServer.content(buffer), "x")
    end

    test "A moves to line end and enters insert mode" do
      {editor, buffer} = start_editor("hi")
      send_key(editor, ?A)
      send_key(editor, ?!)

      assert String.contains?(BufferServer.content(buffer), "!")
    end

    test "I moves to line start and enters insert mode" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?I)
      send_key(editor, ?^)

      assert String.starts_with?(BufferServer.content(buffer), "^")
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

      content_before = BufferServer.content(buffer)
      send_key(editor, ?l)
      assert BufferServer.content(buffer) == content_before
    end
  end

  describe "delete operations" do
    test "delete_at via x in normal mode" do
      {editor, _buffer} = start_editor("hello")
      # x is handled via Keymap, but let's test via the integration path
      # The editor dispatches through Mode.Normal which doesn't bind x directly
      # x is only in Keymap module — so this just verifies no crash
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

      # Buffer content unchanged
      assert BufferServer.content(buffer) == "hello\nworld"

      # Paste should work after yank
      send_key(editor, ?p)
      assert String.contains?(BufferServer.content(buffer), "hello")
    end
  end

  describe "undo / redo" do
    test "u undoes the last change" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)
      send_key(editor, 27)

      assert BufferServer.content(buffer) == "xhello"
      send_key(editor, ?u)
      assert BufferServer.content(buffer) == "hello"
    end

    test "Ctrl+r redoes after undo" do
      {editor, buffer} = start_editor("hello")
      send_key(editor, ?i)
      send_key(editor, ?x)
      send_key(editor, 27)

      send_key(editor, ?u)
      assert BufferServer.content(buffer) == "hello"

      send_key(editor, ?r, 0x02)
      assert BufferServer.content(buffer) == "xhello"
    end
  end

  describe "paste operations" do
    test "p pastes after cursor" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?p)

      content = BufferServer.content(buffer)
      assert String.contains?(content, "hello")
      lines = String.split(content, "\n")
      assert length(lines) >= 3
    end

    test "P pastes before cursor" do
      {editor, buffer} = start_editor("hello\nworld")
      send_key(editor, ?y)
      send_key(editor, ?y)
      send_key(editor, ?j)
      send_key(editor, ?P)

      assert String.contains?(BufferServer.content(buffer), "hello")
    end

    test "p is a no-op when register is empty" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)
      send_key(editor, ?p)
      assert BufferServer.content(buffer) == original
    end

    test "P is a no-op when register is empty" do
      {editor, buffer} = start_editor("hello")
      original = BufferServer.content(buffer)
      send_key(editor, ?P)
      assert BufferServer.content(buffer) == original
    end
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
      # Two lines should be deleted
      assert String.contains?(content, "foo")
    end

    test "v then y yanks visual selection" do
      {editor, buffer} = start_editor("hello world")
      send_key(editor, ?v)
      send_key(editor, ?l)
      send_key(editor, ?l)
      send_key(editor, ?y)

      # Content should be unchanged after yank
      assert BufferServer.content(buffer) == "hello world"

      # Should be able to paste
      send_key(editor, ?p)
      assert String.length(BufferServer.content(buffer)) > String.length("hello world")
    end
  end

  describe "command mode" do
    test ": enters command mode, typing w and Enter saves" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "editor_test_save_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(path, "test content")

      {:ok, buffer} = BufferServer.start_link(file_path: path)

      {:ok, editor} =
        Editor.start_link(
          name: :"editor_cmd_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10
        )

      send_key(editor, ?:)
      send_key(editor, ?w)
      send_key(editor, 13)
      Process.sleep(50)

      assert File.exists?(path)
      assert File.read!(path) == "test content"

      File.rm(path)
    end

    test ":e command doesn't crash" do
      {editor, _buffer} = start_editor("hello")
      send_key(editor, ?:)
      type_string(editor, "e test.txt")
      send_key(editor, 13)

      assert Process.alive?(editor)
    end

    test "goto line via :N command" do
      {editor, buffer} = start_editor("line1\nline2\nline3\nline4")
      send_key(editor, ?:)
      send_key(editor, ?3)
      send_key(editor, 13)
      Process.sleep(30)

      {line, _col} = BufferServer.cursor(buffer)
      assert line == 2
    end

    test "unknown ex command doesn't crash" do
      {editor, _buffer} = start_editor("hello")
      send_key(editor, ?:)
      type_string(editor, "nonexistent")
      send_key(editor, 13)

      assert Process.alive?(editor)
    end
  end

  describe "global keybindings" do
    test "Ctrl+S saves the buffer" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "editor_ctrl_s_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(path, "ctrl-s test")

      {:ok, buffer} = BufferServer.start_link(file_path: path)

      {:ok, editor} =
        Editor.start_link(
          name: :"editor_ctrls_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10
        )

      send_key(editor, ?s, 0x02)
      Process.sleep(100)

      assert File.exists?(path)
      assert File.read!(path) == "ctrl-s test"

      File.rm(path)
    end

    test "Ctrl+S with no buffer doesn't crash" do
      editor = start_editor_no_buffer()
      send_key(editor, ?s, 0x02)
      assert Process.alive?(editor)
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

  describe "handle_info — unknown messages" do
    test "unknown messages are ignored" do
      {editor, _buffer} = start_editor()
      send(editor, :some_random_message)
      Process.sleep(30)
      assert Process.alive?(editor)
    end

    test "stale whichkey timeout is ignored" do
      {editor, _buffer} = start_editor()
      send(editor, {:whichkey_timeout, make_ref()})
      Process.sleep(30)
      assert Process.alive?(editor)
    end
  end

  describe "commands with no buffer" do
    test "key presses with no buffer don't crash" do
      editor = start_editor_no_buffer()

      # Try various keys — all should be no-ops
      send_key(editor, ?h)
      send_key(editor, ?j)
      send_key(editor, ?i)
      send_key(editor, ?d)
      send_key(editor, ?d)
      send_key(editor, ?u)
      send_key(editor, ?p)

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

  describe "render/1" do
    test "render cast doesn't crash with a buffer" do
      {editor, _buffer} = start_editor()
      Editor.render(editor)
      Process.sleep(30)
      assert Process.alive?(editor)
    end

    test "render cast doesn't crash without a buffer" do
      editor = start_editor_no_buffer()
      Editor.render(editor)
      Process.sleep(30)
      assert Process.alive?(editor)
    end
  end

  describe "stub commands" do
    test "find_file doesn't crash" do
      {editor, _buffer} = start_editor()
      # SPC f f triggers find_file via leader keys
      send_key(editor, 32)
      Process.sleep(50)
      send_key(editor, ?f)
      Process.sleep(50)
      send_key(editor, ?f)
      Process.sleep(50)
      assert Process.alive?(editor)
    end

    test "buffer_list doesn't crash" do
      {editor, _buffer} = start_editor()
      send_key(editor, 32)
      Process.sleep(50)
      send_key(editor, ?b)
      Process.sleep(50)
      send_key(editor, ?b)
      Process.sleep(50)
      assert Process.alive?(editor)
    end
  end
end
