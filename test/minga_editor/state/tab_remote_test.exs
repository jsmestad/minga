defmodule MingaEditor.State.TabRemoteTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Tab
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.RemoteSession

  test "display_label prefixes remote server name" do
    pid = spawn(fn -> :ok end)

    workspace =
      Workspace.new_agent(1, "Agent", pid)
      |> Workspace.set_remote_session(RemoteSession.new("home", "session-1", :connected))

    tab =
      1
      |> Tab.new_agent("Agent")
      |> Tab.project_agent_lifecycle(workspace)

    assert Tab.display_label(tab) == "[home] Agent"
    assert Tab.remote?(tab)

    disconnected =
      workspace
      |> Workspace.set_remote_connection_status(:disconnected)
      |> then(&Tab.project_agent_lifecycle(tab, &1))

    assert Tab.display_label(disconnected) == "[home] Agent [disconnected]"
  end
end
