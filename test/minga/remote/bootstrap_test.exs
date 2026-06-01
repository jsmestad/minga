defmodule Minga.Remote.BootstrapTest do
  # Boots a real peer node and mutates Application env, so this file must stay serial.
  use Minga.Test.DistributedCase, async: false

  alias Minga.Remote.Bootstrap
  alias Minga.Remote.SessionURL
  alias MingaAgent.RemoteAPI
  alias MingaAgent.SessionManager

  @moduletag :distributed

  setup_all do
    System.cmd("epmd", ["-daemon"])
    :ok
  end

  setup do
    old_skip = Application.get_env(:minga, :remote_skip_ssh_bootstrap)
    old_node = Application.get_env(:minga, :remote_node_name)
    old_attempts = Application.get_env(:minga, :remote_node_connect_attempts)
    old_interval = Application.get_env(:minga, :remote_node_connect_retry_interval_ms)

    Application.put_env(:minga, :remote_skip_ssh_bootstrap, true)

    on_exit(fn ->
      if old_skip == nil do
        Application.delete_env(:minga, :remote_skip_ssh_bootstrap)
      else
        Application.put_env(:minga, :remote_skip_ssh_bootstrap, old_skip)
      end

      if old_node == nil do
        Application.delete_env(:minga, :remote_node_name)
      else
        Application.put_env(:minga, :remote_node_name, old_node)
      end

      if old_attempts == nil do
        Application.delete_env(:minga, :remote_node_connect_attempts)
      else
        Application.put_env(:minga, :remote_node_connect_attempts, old_attempts)
      end

      if old_interval == nil do
        Application.delete_env(:minga, :remote_node_connect_retry_interval_ms)
      else
        Application.put_env(:minga, :remote_node_connect_retry_interval_ms, old_interval)
      end
    end)

    :ok
  end

  test "connect_remote_node rejects invalid and overlong distributed node names" do
    Application.put_env(:minga, :remote_node_name, "bad node name")
    assert {:error, :invalid_node_name} = Bootstrap.connect_remote_node(url())

    Application.put_env(:minga, :remote_node_name, String.duplicate("a", 256))
    assert {:error, :invalid_node_name} = Bootstrap.connect_remote_node(url())
  end

  test "connect_remote_node reports failure after bounded retries" do
    node = :"missing_minga_bootstrap_#{System.unique_integer([:positive])}@127.0.0.1"
    Application.put_env(:minga, :remote_node_name, Atom.to_string(node))
    Application.put_env(:minga, :remote_node_connect_attempts, 1)
    Application.put_env(:minga, :remote_node_connect_retry_interval_ms, 0)

    assert {:error, {:node_connect_failed, ^node}} = Bootstrap.connect_remote_node(url())
  end

  test "attach unwraps broker start result and returns session metadata" do
    peer = start_peer()
    on_exit(fn -> stop_peer(peer) end)
    Application.put_env(:minga, :remote_node_name, Atom.to_string(peer.node))

    assert {:ok, result} = Bootstrap.attach(url())
    assert result.remote_node == peer.node
    assert result.session_id != ""
    assert result.workdir == "/work/app"
    assert is_pid(result.pid)
    assert is_binary(result.token)
  end

  test "kill_session returns not_found when no workdir session exists" do
    peer = start_peer()
    on_exit(fn -> stop_peer(peer) end)

    Application.put_env(:minga, :remote_node_name, Atom.to_string(peer.node))

    assert {:error, :not_found} = Bootstrap.kill_session(url())
  end

  test "kill_session stops the existing workdir session without creating a new one" do
    peer = start_peer()
    on_exit(fn -> stop_peer(peer) end)
    Application.put_env(:minga, :remote_node_name, Atom.to_string(peer.node))

    workdir =
      Path.join(System.tmp_dir!(), "minga-bootstrap-#{System.unique_integer([:positive])}")

    {:ok, %{session_id: session_id}} =
      :erpc.call(peer.node, RemoteAPI, :start_or_get_for_workdir, [workdir])

    assert :ok = Bootstrap.kill_session(url(workdir))

    assert {:error, :not_found} =
             :erpc.call(peer.node, SessionManager, :get_session, [session_id])
  end

  defp start_peer do
    name = :"minga_bootstrap_#{System.unique_integer([:positive])}@127.0.0.1"
    {:ok, peer} = start_peer_node(name)

    db_dir =
      Path.join(System.tmp_dir!(), "minga-bootstrap-events-#{System.unique_integer([:positive])}")

    {:ok, _runtime} =
      :erpc.call(peer.node, Minga.Test.RemoteAgentRuntime, :start_link, [[db_dir: db_dir]])

    peer
  end

  defp stop_peer(peer) do
    stop_peer_node(peer)
  end

  defp url(path \\ "/work/app") do
    {:ok, url} = SessionURL.parse("ssh://devbox#{path}")
    url
  end
end
