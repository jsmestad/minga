defmodule MingaAgent.RemoteAPITest do
  # Uses the global MingaAgent.SessionManager broker boundary.
  use ExUnit.Case, async: false

  alias MingaAgent.RemoteAPI
  alias MingaAgent.SessionManager

  setup do
    started = []

    on_exit(fn ->
      Enum.each(started, fn session_id -> SessionManager.stop_session(session_id) end)
    end)

    %{started: started}
  end

  test "start_session returns a broker token and rejects the wrong token", %{started: started} do
    assert {:ok, %{session_id: session_id, pid: pid, token: token}} = RemoteAPI.start_session([])
    started = [session_id | started]

    assert is_pid(pid)
    assert is_binary(token)
    assert :ok = RemoteAPI.authorize(session_id, token)
    assert {:error, :unauthorized} = RemoteAPI.authorize(session_id, "wrong-token")

    Enum.each(started, fn id -> SessionManager.stop_session(id) end)
  end

  test "attach assigns one driver and refuses viewer mutations" do
    assert {:ok, %{session_id: session_id, token: token}} = RemoteAPI.start_session([])
    on_exit(fn -> SessionManager.stop_session(session_id) end)

    driver = idle_process()
    viewer = idle_process()

    on_exit(fn ->
      Process.exit(driver, :kill)
      Process.exit(viewer, :kill)
    end)

    assert {:ok, %{role: :driver, messages: messages, snapshot: snapshot}} =
             RemoteAPI.attach(session_id, token, driver, role: :driver)

    assert is_list(messages)
    assert is_map(snapshot)

    assert {:ok, %{role: :viewer}} = RemoteAPI.attach(session_id, token, viewer, role: :driver)
    assert {:error, :not_driver} = RemoteAPI.send_prompt(session_id, token, viewer, "not allowed")
  end

  test "start_or_get_for_workdir reuses the deterministic session" do
    workdir = Path.join(System.tmp_dir!(), "remote-api-workdir")

    assert {:ok, %{session_id: session_id, pid: pid}} =
             RemoteAPI.start_or_get_for_workdir(workdir)

    on_exit(fn -> SessionManager.stop_session(session_id) end)

    assert {:ok, %{session_id: ^session_id, pid: ^pid}} =
             RemoteAPI.start_or_get_for_workdir(workdir)
  end

  @spec idle_process() :: pid()
  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end
end
