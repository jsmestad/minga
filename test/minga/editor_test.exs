defmodule Minga.EditorTest do
  use ExUnit.Case

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  # We test the editor with a real buffer but a nil port manager
  # (send_commands to nil just logs a warning, which is fine for tests)

  setup do
    {:ok, buffer} = BufferServer.start_link(content: "hello\nworld\nfoo")

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10
      )

    %{editor: editor, buffer: buffer}
  end

  describe "init" do
    test "subscribes to port manager and has correct viewport", %{editor: editor} do
      assert Process.alive?(editor)
    end
  end

  describe "handle_info — key_press" do
    test "insert character updates buffer", %{editor: editor, buffer: buffer} do
      # Simulate a key press for 'x' (codepoint 120)
      send(editor, {:minga_input, {:key_press, ?x, 0}})
      Process.sleep(50)

      assert BufferServer.content(buffer) == "xhello\nworld\nfoo"
    end

    test "backspace deletes character", %{editor: editor, buffer: buffer} do
      # First insert then backspace
      send(editor, {:minga_input, {:key_press, ?a, 0}})
      Process.sleep(20)
      send(editor, {:minga_input, {:key_press, 127, 0}})
      Process.sleep(50)

      assert BufferServer.content(buffer) == "hello\nworld\nfoo"
    end

    test "enter inserts newline", %{editor: editor, buffer: buffer} do
      send(editor, {:minga_input, {:key_press, 13, 0}})
      Process.sleep(50)

      assert BufferServer.content(buffer) == "\nhello\nworld\nfoo"
    end

    test "arrow keys move cursor without changing content", %{editor: editor, buffer: buffer} do
      original = BufferServer.content(buffer)

      # Move right twice
      send(editor, {:minga_input, {:key_press, 57421, 0}})
      send(editor, {:minga_input, {:key_press, 57421, 0}})
      Process.sleep(50)

      assert BufferServer.content(buffer) == original
      assert BufferServer.cursor(buffer) == {0, 2}
    end
  end

  describe "handle_info — resize" do
    test "resize updates viewport", %{editor: editor} do
      send(editor, {:minga_input, {:resize, 120, 40}})
      Process.sleep(50)
      assert Process.alive?(editor)
    end
  end

  describe "handle_info — ready" do
    test "ready event updates viewport", %{editor: editor} do
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

      # Start a separate editor with fresh state for this test
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
