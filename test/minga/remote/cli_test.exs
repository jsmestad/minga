defmodule Minga.Remote.CLITest do
  # Uses Application env and a real distributed peer node, so this file must stay serial.
  use Minga.Test.DistributedCase, async: false

  import ExUnit.CaptureIO

  alias Minga.Remote.Bootstrap
  alias Minga.Remote.CLI

  setup_all do
    System.cmd("epmd", ["-daemon"])
    :ok
  end

  defmodule StubBootstrap do
    @spec attach(Minga.Remote.SessionURL.t()) :: {:ok, Bootstrap.attach_result()}
    def attach(url) do
      {:ok,
       %Bootstrap{
         server_name: url.host,
         remote_node: :"minga_server@#{url.host}",
         session_id: "session-work",
         pid: self(),
         token: "token",
         workdir: url.path
       }}
    end

    @spec sessions(Minga.Remote.SessionURL.t()) :: {:ok, [Bootstrap.session_row()]}
    def sessions(_url) do
      {:ok, [%{session_id: "session-work", workdir: "/work/app", status: :idle, recent: "hello"}]}
    end

    @spec kill_session(Minga.Remote.SessionURL.t()) :: :ok
    def kill_session(_url), do: :ok
  end

  setup do
    old = Application.get_env(:minga, :remote_bootstrap)
    Application.put_env(:minga, :remote_bootstrap, StubBootstrap)

    on_exit(fn ->
      if old == nil do
        Application.delete_env(:minga, :remote_bootstrap)
      else
        Application.put_env(:minga, :remote_bootstrap, old)
      end

      Application.delete_env(:minga, :pending_remote_attach)
      Application.delete_env(:minga, :local_control_endpoint_path)
    end)

    :ok
  end

  test "attach bootstraps and stores pending remote attach metadata" do
    assert {:ok, result} = CLI.attach("ssh://devbox/work/app")
    assert result.session_id == "session-work"
    assert result.workdir == "/work/app"
    assert Application.get_env(:minga, :pending_remote_attach) == result
  end

  test "sessions prints remote session rows without launching editor" do
    output = capture_io(fn -> assert :ok = CLI.sessions("ssh://devbox") end)

    assert output =~ "session-work"
    assert output =~ "/work/app"
    assert output =~ "idle"
  end

  test "detach uses the local control endpoint to reach the running editor node" do
    peer_name = :"minga_editor_control_#{System.unique_integer([:positive])}@127.0.0.1"
    {:ok, peer} = start_peer_node(peer_name)
    on_exit(fn -> stop_peer_node(peer) end)

    control_path =
      Path.join(System.tmp_dir!(), "minga-control-#{System.unique_integer([:positive])}.node")

    Application.put_env(:minga, :local_control_endpoint_path, control_path)
    File.write!(control_path, "#{peer.node}\n")
    on_exit(fn -> File.rm(control_path) end)

    {:ok, editor_pid} =
      :erpc.call(peer.node, Minga.Test.RemoteControlEditor, :start_link, [self()])

    on_exit(fn -> :erpc.call(peer.node, Process, :exit, [editor_pid, :kill]) end)

    output = capture_io(fn -> assert :ok = CLI.detach() end)
    assert output =~ "Detached local frontend"
    assert_receive :detached, 1_000
  end

  test "detach reports a clear error when no local control endpoint exists" do
    control_path =
      Path.join(
        System.tmp_dir!(),
        "missing-minga-control-#{System.unique_integer([:positive])}.node"
      )

    Application.put_env(:minga, :local_control_endpoint_path, control_path)

    assert {:error, message} = CLI.detach()
    assert message =~ "no local frontend control endpoint available"
  end

  test "kill-session delegates to bootstrap and prints confirmation" do
    output = capture_io(fn -> assert :ok = CLI.kill_session("ssh://devbox/work/app") end)

    assert output =~ "Stopped remote session"
    assert output =~ "/work/app"
  end
end
