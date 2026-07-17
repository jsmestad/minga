defmodule MingaAgent.RemoteAPITest do
  use ExUnit.Case, async: true

  alias MingaAgent.RemoteAPI
  alias MingaAgent.SessionManager

  @moduletag :tmp_dir

  test "authorization accepts only the manager-owned session token", %{tmp_dir: dir} do
    session_id = "remote-api-auth-#{System.unique_integer([:positive])}"

    assert {:ok, ^session_id, _pid} =
             SessionManager.start_session(session_id: session_id, session_store_dir: dir)

    on_exit(fn -> SessionManager.stop_session(session_id) end)

    assert {:ok, token} = SessionManager.session_token(session_id)
    assert :ok = RemoteAPI.authorize(session_id, token)
    assert {:error, :unauthorized} = RemoteAPI.authorize(session_id, "invalid-token")
  end
end
