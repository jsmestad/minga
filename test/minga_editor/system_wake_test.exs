defmodule MingaEditor.SystemWakeTest do
  # async: false because this test mutates the singleton LSP SyncServer ETS table.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.LSP.SyncServer
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  test "system wake resyncs inactive tab buffers" do
    active_buffer =
      start_supervised!({BufferProcess, content: "active", file_path: "/tmp/wake_active.txt"},
        id: :wake_active_buffer
      )

    inactive_buffer =
      start_supervised!({BufferProcess, content: "inactive", file_path: "/tmp/wake_inactive.txt"},
        id: :wake_inactive_buffer
      )

    editor =
      start_supervised!(
        {MingaEditor,
         name: :"editor_#{System.unique_integer([:positive])}",
         backend: :headless,
         port_manager: nil,
         buffer: active_buffer,
         width: 40,
         height: 10,
         editing_model: :vim}
      )

    stale_client = spawn(fn -> receive do: (_ -> :ok) end)
    on_exit(fn -> Process.exit(stale_client, :kill) end)
    :ets.insert(SyncServer.Registry, {inactive_buffer, [stale_client]})

    :sys.replace_state(editor, fn state ->
      active_tab =
        Tab.new_file(1, "active")
        |> Tab.set_context(%{buffers: %Buffers{active: active_buffer, list: [active_buffer]}})

      inactive_tab =
        Tab.new_file(2, "inactive")
        |> Tab.set_context(%{buffers: %Buffers{active: inactive_buffer, list: [inactive_buffer]}})

      tab_bar = %TabBar{tabs: [active_tab, inactive_tab], active_id: 1, next_id: 3}
      EditorState.set_tab_bar(state, tab_bar)
    end)

    send(editor, {:minga_input, {:gui_action, :system_did_wake}})

    :sys.get_state(editor)
    :sys.get_state(SyncServer)

    assert SyncServer.clients_for_buffer(inactive_buffer) == []
  end
end
