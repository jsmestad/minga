defmodule Minga.Editor.Commands.BufferManagementTest do
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

  defp type_string(editor, text) do
    text
    |> String.to_charlist()
    |> Enum.each(fn char -> send_key(editor, char) end)
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
      _ = :sys.get_state(editor)

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
      _ = :sys.get_state(editor)

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
      _ = :sys.get_state(editor)

      assert File.exists?(path)
      assert File.read!(path) == "ctrl-s test"

      File.rm(path)
    end

    test "Ctrl+S with no buffer doesn't crash" do
      {:ok, editor} =
        Editor.start_link(
          name: :"editor_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: nil,
          width: 40,
          height: 10
        )

      send_key(editor, ?s, 0x02)
      assert Process.alive?(editor)
    end
  end
end
