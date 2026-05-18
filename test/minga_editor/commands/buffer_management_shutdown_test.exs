defmodule MingaEditor.Commands.BufferManagementShutdownTest do
  # Mutates Application env (:shutdown_fn), so these shutdown-path tests cannot run async.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor

  setup do
    previous_shutdown_fn = Application.fetch_env(:minga, :shutdown_fn)
    test_pid = self()

    Application.put_env(:minga, :shutdown_fn, fn status ->
      send(test_pid, {:shutdown_called, status})
    end)

    on_exit(fn ->
      case previous_shutdown_fn do
        {:ok, shutdown_fn} -> Application.put_env(:minga, :shutdown_fn, shutdown_fn)
        :error -> Application.delete_env(:minga, :shutdown_fn)
      end
    end)
  end

  describe "shutdown-path editor integration" do
    test "quit all with a clean buffer exits without confirmation" do
      {editor, _buffer, _options} = start_editor("hello")

      type_string(editor, ":qa\r")

      assert_receive {:shutdown_called, 0}
    end

    test "force quit all bypasses dirty-buffer confirmation" do
      {editor, buffer, _options} = start_editor("hello")
      BufferProcess.insert_char(buffer, "X")
      assert BufferProcess.dirty?(buffer)

      type_string(editor, ":qa!\r")

      assert_receive {:shutdown_called, 0}
    end

    test "confirm_quit false disables the dirty-buffer quit-all prompt" do
      {editor, buffer, options} = start_editor("hello")
      BufferProcess.insert_char(buffer, "X")
      assert BufferProcess.dirty?(buffer)
      assert {:ok, false} = Options.set(options, :confirm_quit, false)

      type_string(editor, ":qa\r")

      assert_receive {:shutdown_called, 0}
    end

    test ":cq and :cq! exit with non-zero status" do
      {editor, _buffer, _options} = start_editor("hello")
      type_string(editor, ":cq\r")
      assert_receive {:shutdown_called, 1}

      {editor, _buffer, _options} = start_editor("hello")
      type_string(editor, ":cq!\r")
      assert_receive {:shutdown_called, 1}
    end
  end

  defp start_editor(content) do
    {:ok, buffer} = BufferProcess.start_link(content: content)
    {:ok, options} = Options.start_link(name: nil)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_shutdown_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        options_server: options,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim
      )

    {editor, buffer, options}
  end

  defp type_string(editor, text) do
    text
    |> String.to_charlist()
    |> Enum.each(fn char -> send_key(editor, char) end)
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    GenServer.call(editor, :api_mode)
  end
end
