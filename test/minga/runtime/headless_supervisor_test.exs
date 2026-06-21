defmodule Minga.Runtime.HeadlessSupervisorTest do
  @moduledoc """
  The headless daemon must host attached client editor sessions (#2424).

  `MingaEditor.Collab.SessionManager` and the node-shared `Minga.Parser.Manager`
  only start under `Minga.Runtime.Supervisor`, which is gated off for the
  headless daemon. `Minga.Runtime.HeadlessSupervisor` starts the minimal subset a
  daemon needs so `MingaEditor.Collab.attach/4` does not fail with `:noproc`.
  """

  # async: false: starts the globally-named Parser.Manager and the global
  # MingaEditor.Collab.SessionManager DynamicSupervisor.
  use ExUnit.Case, async: false

  alias MingaAgent.RemoteAPI
  alias MingaAgent.SessionManager, as: AgentSessionManager
  alias MingaEditor.Collab
  alias MingaEditor.Collab.Names
  alias MingaEditor.Collab.SessionManager, as: EditorSessionManager

  setup do
    start_supervised!(Minga.Runtime.HeadlessSupervisor)
    :ok
  end

  test "starts the node-shared parser and the session-hosting DynamicSupervisor" do
    parser = Process.whereis(Minga.Parser.Manager)
    session_manager = Process.whereis(EditorSessionManager)

    assert is_pid(parser)
    assert is_pid(session_manager)
  end

  test "does not start the default interactive triad" do
    # A daemon hosts sessions only on attach; no default editor/renderer/frontend.
    refute is_pid(Names.whereis(Names.default_session_id(), :editor))
    refute Process.whereis(MingaEditor.Frontend.Manager)
    refute Process.whereis(MingaEditor.Renderer.Server)
  end

  test "a client can attach and get a hosted server-side editor under the daemon tree" do
    {:ok, %{session_id: agent_session_id, token: token}} = RemoteAPI.start_session([])
    on_exit(fn -> AgentSessionManager.stop_session(agent_session_id) end)

    client =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(client, :kill) end)

    assert {:ok, result} =
             Collab.attach(agent_session_id, token, client, role: :driver, backend: :headless)

    assert EditorSessionManager.session_running?(result.editor_session_id)
    assert is_pid(Names.whereis(result.editor_session_id, :editor))

    Collab.detach(agent_session_id, token, client)
  end
end
