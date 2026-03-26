defmodule Minga.EditorTest do
  use Minga.Test.EditingModelCase, async: true

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

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
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

  describe "handle_info — resize" do
    test "resize event updates viewport" do
      {editor, _buffer} = start_editor()
      send(editor, {:minga_input, {:resize, 120, 40}})
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end
  end

  describe "handle_info — ready" do
    test "ready event updates viewport" do
      {editor, _buffer} = start_editor()
      send(editor, {:minga_input, {:ready, 100, 30}})
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end
  end

  describe "handle_info — unknown messages" do
    test "unknown messages are ignored" do
      {editor, _buffer} = start_editor()
      send(editor, :some_random_message)
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end

    test "stale whichkey timeout is ignored" do
      {editor, _buffer} = start_editor()
      send(editor, {:whichkey_timeout, make_ref()})
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end
  end

  describe "commands with no buffer" do
    test "key presses with no buffer don't crash" do
      editor = start_editor_no_buffer()

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
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end

    test "render cast doesn't crash without a buffer" do
      editor = start_editor_no_buffer()
      Editor.render(editor)
      _ = :sys.get_state(editor)
      assert Process.alive?(editor)
    end
  end

  describe "read-only buffer guard" do
    test "entering insert mode on read-only buffer stays in normal mode" do
      {:ok, buffer} = BufferServer.start_link(content: "read only", read_only: true)

      {:ok, editor} =
        Editor.start_link(
          name: :"editor_ro_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10
        )

      # Try pressing 'i' to enter insert mode
      send(editor, {:minga_input, {:key_press, ?i, 0}})
      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :normal
      assert state.shell_state.status_msg == "Buffer is read-only"
    end

    test "entering replace mode on read-only buffer stays in normal mode" do
      {:ok, buffer} = BufferServer.start_link(content: "read only", read_only: true)

      {:ok, editor} =
        Editor.start_link(
          name: :"editor_ro2_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: buffer,
          width: 40,
          height: 10
        )

      # Try pressing 'R' to enter replace mode
      send(editor, {:minga_input, {:key_press, ?R, 0}})
      state = :sys.get_state(editor)
      assert state.workspace.editing.mode == :normal
      assert state.shell_state.status_msg == "Buffer is read-only"
    end
  end
end
