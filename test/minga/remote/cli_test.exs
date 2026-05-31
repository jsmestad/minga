defmodule Minga.Remote.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Minga.Remote.Bootstrap
  alias Minga.Remote.CLI

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

  test "kill-session delegates to bootstrap and prints confirmation" do
    output = capture_io(fn -> assert :ok = CLI.kill_session("ssh://devbox/work/app") end)

    assert output =~ "Stopped remote session"
    assert output =~ "/work/app"
  end
end
