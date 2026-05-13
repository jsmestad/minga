defmodule MingaEditor.State.TabRemoteTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Tab

  test "display_label prefixes remote server name" do
    pid = spawn(fn -> :ok end)

    tab =
      1
      |> Tab.new_agent("Agent")
      |> Tab.set_remote_session("home", "session-1", pid)

    assert Tab.display_label(tab) == "[home] Agent"
    assert Tab.remote?(tab)

    disconnected = Tab.set_connection_status(tab, :disconnected)
    assert Tab.display_label(disconnected) == "[home] Agent [disconnected]"
  end
end
