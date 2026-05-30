defmodule Minga.Distribution.RemoteSessionE2ETest do
  @moduledoc """
  End-to-end verification of detachable agent sessions over Erlang distribution
  (proposal #955, Phase 1). Boots a headless runtime on a real peer node (the
  "server"), then drives the full GUI-side flow from the local node:

    * start a session on the server via cross-node call
    * subscribe to the remote session pid and receive agent events across nodes
    * read full history across nodes
    * detach (subscriber dies) and confirm the session survives on the server
    * reattach and confirm state was preserved

  This proves the distribution transport already delivers Phase 1 without any
  custom TCP protocol or remote-session-proxy.

  Tagged `:distributed` and excluded by default (it boots a real peer node and
  needs Erlang distribution / epmd). Run it explicitly:

      mix test --include distributed test/minga/distribution/remote_session_e2e_test.exs
  """
  use Minga.Test.DistributedCase, async: false

  alias MingaAgent.Session
  alias MingaAgent.SessionManager

  @moduletag :distributed

  @stub Minga.Test.StubProvider

  # Real two-node tests need epmd. Ensure it is up before any node starts, so
  # the suite is self-sufficient regardless of how the VM was launched.
  setup_all do
    System.cmd("epmd", ["-daemon"])
    :ok
  end

  setup do
    name = :"minga_server_e2e_#{System.unique_integer([:positive])}@127.0.0.1"
    {:ok, peer} = start_peer_node(name)
    on_exit(fn -> stop_peer_node(peer) end)

    # Make the peer a headless Minga "server": load app + config, point its
    # config dir at a temp location, then boot the headless supervision tree.
    config_home = Path.join(System.tmp_dir!(), "minga-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(config_home, "minga"))
    on_exit(fn -> File.rm_rf(config_home) end)

    # Load the app, copy this VM's :minga config onto the peer, and point its
    # config dir at a temp location, all before starting the application.
    :erpc.call(peer.node, Application, :load, [:minga])
    :ok = :erpc.call(peer.node, Application, :put_all_env, [[minga: Application.get_all_env(:minga)]])
    :erpc.call(peer.node, System, :put_env, [[{"XDG_CONFIG_HOME", config_home}]])

    # The peer never ran test_helper.exs, so seed the ETS stub tables the boot
    # path touches and silence noisy background work.
    :erpc.call(peer.node, Minga.Git.Stub, :ensure_table, [])
    :erpc.call(peer.node, Minga.Tool.Installer.Stub, :ensure_table, [])

    # Boot the full app under the application master (durable, unlike a
    # Supervisor.start_link owned by the ephemeral erpc caller). In the test
    # config start_editor? is false, so this is a headless server: Foundation +
    # Services + Agent, no Port/renderer.
    {:ok, _started} = :erpc.call(peer.node, Application, :ensure_all_started, [:minga])

    %{server: peer.node}
  end

  test "headless server runs an agent session with no GUI attached (AC1)", %{server: server} do
    {:ok, session_id, remote_pid} =
      :erpc.call(server, SessionManager, :start_session, [[provider: @stub]])

    assert is_binary(session_id)
    assert node(remote_pid) == server, "session must live on the server node, not the client"

    # No local subscriber exists. The session is fully functional anyway.
    assert :erpc.call(server, Process, :alive?, [remote_pid])
  end

  test "client subscribes across nodes and receives agent events live (AC3)", %{server: server} do
    {:ok, _id, remote_pid} =
      :erpc.call(server, SessionManager, :start_session, [[provider: @stub]])

    # The local (client) process subscribes to the remote session pid directly.
    :ok = Session.subscribe(remote_pid, self())

    # Drive an event on the server. broadcast/2 is a plain send/2 to subscriber
    # pids, which is network-transparent: the event crosses the node boundary.
    Session.add_system_message(remote_pid, "hello from the server")

    assert_receive {:agent_event, ^remote_pid, :messages_changed}, 2_000

    # Full history is readable across nodes (GenServer.call to a remote pid).
    messages = Session.messages(remote_pid)
    assert Enum.any?(messages, &match?({:system, "hello from the server", _}, &1))
  end

  test "session survives client disconnect and is still listed (AC2 + AC4)", %{server: server} do
    {:ok, session_id, remote_pid} =
      :erpc.call(server, SessionManager, :start_session, [[provider: @stub]])

    Session.add_system_message(remote_pid, "work done while you were away")

    # Simulate a GUI that subscribes, then dies (laptop closed / wifi lost).
    test_pid = self()

    subscriber =
      spawn(fn ->
        Session.subscribe(remote_pid, self())
        send(test_pid, :subscribed)
        Process.sleep(:infinity)
      end)

    assert_receive :subscribed, 1_000
    ref = Process.monitor(subscriber)
    Process.exit(subscriber, :kill)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, _}, 1_000

    # The session keeps running on the server with zero subscribers...
    assert :erpc.call(server, Process, :alive?, [remote_pid])

    # ...and is still enumerable for a reconnecting GUI to find.
    sessions = :erpc.call(server, SessionManager, :list_sessions, [])
    assert Enum.any?(sessions, fn {id, pid, _meta} -> id == session_id and pid == remote_pid end)
  end

  test "reattach after disconnect sees preserved state (AC4)", %{server: server} do
    {:ok, _id, remote_pid} =
      :erpc.call(server, SessionManager, :start_session, [[provider: @stub]])

    Session.add_system_message(remote_pid, "message before disconnect")

    # First client attaches and detaches.
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    :ok = Session.subscribe(remote_pid, agent)
    :ok = Agent.stop(agent)

    # Reconnecting client re-subscribes and snapshots history. The message
    # produced before the disconnect is still there: state lived on the server.
    :ok = Session.subscribe(remote_pid, self())
    messages = Session.messages(remote_pid)
    assert Enum.any?(messages, &match?({:system, "message before disconnect", _}, &1))

    # And the reattached client receives new live events across the node boundary.
    Session.add_system_message(remote_pid, "message after reconnect")
    assert_receive {:agent_event, ^remote_pid, :messages_changed}, 2_000

    assert Enum.any?(
             Session.messages(remote_pid),
             &match?({:system, "message after reconnect", _}, &1)
           )
  end
end
