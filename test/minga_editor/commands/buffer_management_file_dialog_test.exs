defmodule MingaEditor.Commands.BufferManagementFileDialogTest do
  @moduledoc false

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.State.Frontend

  @moduletag :tmp_dir

  test "first Save requests a native destination and applies it to the originating buffer", %{
    tmp_dir: root
  } do
    ctx = start_editor("draft")
    assert :ok = Buffer.insert_text(ctx.buffer, "saved ")
    lifecycle = lifecycle_port(self())
    install_native_frontend(ctx.editor, lifecycle)

    :sys.replace_state(ctx.editor, &BufferManagement.execute(&1, :save))

    assert_receive {:file_dialog_command, command}
    assert {1, :save_as, _suggested_path} = decode_gui_request(command)
    assert {:save_as, 1, originating_buffer} = :sys.get_state(ctx.editor).frontend.file_dialog
    assert originating_buffer == ctx.buffer

    target = Path.join(root, "first-save.txt")
    send_file_dialog_result(ctx.editor, 1, {:save_as, target})

    assert File.read!(target) == "saved draft"
    assert Buffer.file_path(ctx.buffer) == target
    refute Buffer.dirty?(ctx.buffer)
  end

  test "delayed Save As completion writes the originating buffer after focus switches", %{
    tmp_dir: root
  } do
    other_path = Path.join(root, "other.txt")
    target = Path.join(root, "origin.txt")
    File.write!(other_path, "other")
    ctx = start_editor("origin")
    assert :ok = Buffer.insert_text(ctx.buffer, "changed ")
    lifecycle = lifecycle_port(self())
    install_native_frontend(ctx.editor, lifecycle)

    :sys.replace_state(ctx.editor, &BufferManagement.execute(&1, :save_as_dialog))
    assert_receive {:file_dialog_command, _command}

    deliver_gui_action(ctx.editor, {:open_file, other_path})
    refute :sys.get_state(ctx.editor).workspace.buffers.active == ctx.buffer

    send_file_dialog_result(ctx.editor, 1, {:save_as, target})

    assert File.read!(target) == "changed origin"
    assert Buffer.file_path(ctx.buffer) == target
    assert Buffer.file_path(:sys.get_state(ctx.editor).workspace.buffers.active) == other_path
  end

  test "cancel preserves an unnamed buffer's dirty contents", %{tmp_dir: root} do
    ctx = start_editor("draft")
    assert :ok = Buffer.insert_text(ctx.buffer, "changed ")
    lifecycle = lifecycle_port(self())
    install_native_frontend(ctx.editor, lifecycle)

    :sys.replace_state(ctx.editor, &BufferManagement.execute(&1, :save_as_dialog))
    assert_receive {:file_dialog_command, _command}
    send_file_dialog_result(ctx.editor, 1, :cancel)

    assert Buffer.content(ctx.buffer) == "changed draft"
    assert Buffer.file_path(ctx.buffer) == nil
    assert Buffer.dirty?(ctx.buffer)
    assert :sys.get_state(ctx.editor).frontend.file_dialog == :idle
    refute File.exists?(Path.join(root, "draft"))
  end

  test "Save As completion does not write after the originating buffer closes", %{tmp_dir: root} do
    target = Path.join(root, "closed.txt")
    ctx = start_editor("draft")
    assert :ok = Buffer.insert_text(ctx.buffer, "changed ")
    lifecycle = lifecycle_port(self())
    install_native_frontend(ctx.editor, lifecycle)

    :sys.replace_state(ctx.editor, &BufferManagement.execute(&1, :save_as_dialog))
    assert_receive {:file_dialog_command, _command}
    :sys.replace_state(ctx.editor, &BufferManagement.execute(&1, :force_kill_buffer))
    send_file_dialog_result(ctx.editor, 1, {:save_as, target})

    refute File.exists?(target)
    assert notice_message(ctx) == "Save As failed: original buffer is no longer open"
  end

  test "failed Save As preserves contents and dirty state", %{tmp_dir: root} do
    ctx = start_editor("draft")
    assert :ok = Buffer.insert_text(ctx.buffer, "changed ")
    lifecycle = lifecycle_port(self())
    install_native_frontend(ctx.editor, lifecycle)

    :sys.replace_state(ctx.editor, &BufferManagement.execute(&1, :save_as_dialog))
    assert_receive {:file_dialog_command, _command}
    invalid_target = Path.join(root, "directory-target")
    File.mkdir!(invalid_target)
    send_file_dialog_result(ctx.editor, 1, {:save_as, invalid_target})

    assert Buffer.content(ctx.buffer) == "changed draft"
    assert Buffer.file_path(ctx.buffer) == nil
    assert Buffer.dirty?(ctx.buffer)
    assert notice_message(ctx) =~ "Save failed:"
    assert File.dir?(invalid_target)
  end

  test "Open accepts multiple selected files in one correlated result", %{tmp_dir: root} do
    first = Path.join(root, "first.txt")
    second = Path.join(root, "second.txt")
    File.write!(first, "first")
    File.write!(second, "second")
    ctx = start_editor("initial")
    lifecycle = lifecycle_port(self())
    install_native_frontend(ctx.editor, lifecycle)

    :sys.replace_state(ctx.editor, &BufferManagement.execute(&1, :open_file_dialog))

    assert_receive {:file_dialog_command, command}
    assert {1, :open, ""} = decode_gui_request(command)
    send_file_dialog_result(ctx.editor, 1, {:open, [first, second]})

    state = :sys.get_state(ctx.editor)
    paths = Enum.map(state.workspace.buffers.list, &Buffer.file_path/1)
    assert first in paths
    assert second in paths
    assert Buffer.file_path(state.workspace.buffers.active) == second
  end

  defp install_native_frontend(editor, port_manager) do
    :sys.replace_state(editor, fn state ->
      capabilities = %Capabilities{frontend_type: :native_gui, semantic_ui: true}
      %Frontend{} = current_frontend = state.frontend

      frontend = %Frontend{
        current_frontend
        | capabilities: capabilities,
          port_manager: port_manager
      }

      %{state | frontend: frontend}
    end)
  end

  defp lifecycle_port(parent) do
    {:ok, pid} = Task.start_link(fn -> lifecycle_port_loop(parent) end)
    pid
  end

  defp lifecycle_port_loop(parent) do
    receive do
      {:"$gen_call", from, {:send_lifecycle_command, command}} ->
        send(parent, {:file_dialog_command, command})
        GenServer.reply(from, :accepted)
        lifecycle_port_loop(parent)
    end
  end

  defp decode_gui_request(<<_opcode, payload_length::16, payload::binary-size(payload_length)>>) do
    <<request_id::32, kind::8, path_length::16, path::binary-size(path_length)>> = payload
    {request_id, decode_request_kind(kind), path}
  end

  defp decode_request_kind(0), do: :open
  defp decode_request_kind(1), do: :save_as

  defp send_file_dialog_result(editor, request_id, result) do
    deliver_gui_action(editor, {:file_dialog_result, request_id, result})
  end

  defp deliver_gui_action(editor, action) do
    send(editor, {:minga_input, {:gui_action, action}})
    _state = :sys.get_state(editor)
    :ok
  end
end
