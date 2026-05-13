defmodule MingaEditor.RemoteNodeEventsTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Distribution.Events.NodeConnectedEvent
  alias Minga.Distribution.Events.NodeDisconnectedEvent
  alias MingaEditor.State.Remote

  test "node_connected marks the remote server connected" do
    ctx = start_editor("initial")

    send(ctx.editor, {
      :minga_event,
      :node_connected,
      %NodeConnectedEvent{
        server_name: "home",
        node: node(),
        connected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)

    assert Remote.server_status(state.remote, "home") == :connected
    assert state.shell_state.status_msg =~ "Connected to home"
  end

  test "node_disconnected marks the remote server disconnected" do
    ctx = start_editor("initial")

    send(ctx.editor, {
      :minga_event,
      :node_disconnected,
      %NodeDisconnectedEvent{
        server_name: "home",
        node: :"missing@127.0.0.1",
        reason: :nodedown,
        disconnected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)

    assert Remote.server_status(state.remote, "home") == :disconnected
    assert state.shell_state.status_msg == "[home] disconnected, reconnecting..."
  end
end
