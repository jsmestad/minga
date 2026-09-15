defmodule MingaAgent.RemoteAPITest do
  # RemoteAPI is fixed to the global SessionManager, so this test cannot isolate manager state.
  use ExUnit.Case, async: false

  alias MingaAgent.RemoteAPI
  alias MingaAgent.RemoteAPI.SessionInfo
  alias MingaAgent.SessionListing
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionMetadata

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

  test "start_session preserves the healthy metadata contract", %{tmp_dir: dir} do
    assert {:ok,
            %SessionInfo{
              session_id: session_id,
              pid: pid,
              token: token,
              metadata: %SessionMetadata{} = metadata,
              details: {:available, metadata}
            }} =
             RemoteAPI.start_session(
               provider: Minga.Test.StubProvider,
               session_store_dir: dir
             )

    on_exit(fn -> SessionManager.stop_session(session_id) end)

    assert metadata.id == session_id
    assert is_pid(pid)
    assert is_binary(token)
  end

  test "start_or_get_for_workdir preserves the healthy metadata contract", %{tmp_dir: dir} do
    workdir = Path.join(dir, "project")

    assert {:ok,
            %SessionInfo{
              session_id: session_id,
              metadata: %SessionMetadata{workdir: ^workdir} = metadata,
              details: {:available, metadata}
            }} =
             RemoteAPI.start_or_get_for_workdir(workdir,
               provider: Minga.Test.StubProvider,
               session_store_dir: dir
             )

    on_exit(fn -> SessionManager.stop_session(session_id) end)
    assert metadata.id == session_id
  end

  test "attach preserves complete metadata for a healthy session", %{tmp_dir: dir} do
    assert {:ok, %SessionInfo{session_id: session_id, token: token, metadata: metadata}} =
             RemoteAPI.start_session(
               provider: Minga.Test.StubProvider,
               session_store_dir: dir
             )

    on_exit(fn -> SessionManager.stop_session(session_id) end)

    assert {:ok, result} =
             RemoteAPI.attach(session_id, token, self(), role: :driver)

    assert result.session_id == session_id
    assert result.metadata == metadata
  end

  test "listing preserves a timed-out registration without a second metadata query", %{
    tmp_dir: dir
  } do
    session_id = "remote-api-timeout-#{System.unique_integer([:positive])}"

    assert {:ok, ^session_id, pid} =
             SessionManager.start_session(
               session_id: session_id,
               session_store_dir: dir,
               provider: Minga.Test.StubProvider
             )

    assert {:ok, token} = SessionManager.session_token(session_id)
    :ok = :sys.suspend(pid)

    on_exit(fn ->
      if Process.info(pid, :status) == {:status, :suspended}, do: :sys.resume(pid)
      SessionManager.stop_session(session_id)
    end)

    assert %SessionInfo{
             session_id: ^session_id,
             pid: ^pid,
             token: ^token,
             details: {:unavailable, :timeout},
             metadata: nil
           } = Enum.find(RemoteAPI.list_sessions(), &(&1.session_id == session_id))

    assert {:ok, ^pid} = SessionManager.get_session(session_id)
    :ok = :sys.resume(pid)

    assert %SessionInfo{
             session_id: ^session_id,
             pid: ^pid,
             token: ^token,
             details: {:available, metadata}
           } = Enum.find(RemoteAPI.list_sessions(), &(&1.session_id == session_id))

    assert metadata.id == session_id
  end

  test "normalizes supported older records and rejects unsupported shapes" do
    now = DateTime.utc_now()

    metadata = %{
      id: "older",
      title: nil,
      model_name: "real-model",
      provider_name: "provider",
      created_at: now,
      last_message_at: now,
      message_count: 3,
      turn_count: 2,
      first_prompt: "prompt",
      cost: 0.1,
      status: :idle,
      workdir: "/tmp/project"
    }

    assert {:ok,
            %SessionInfo{
              session_id: "older",
              details: {:available, ^metadata}
            }} =
             SessionInfo.normalize(%{
               session_id: "older",
               pid: self(),
               token: "token",
               metadata: metadata
             })

    assert {:error, :unsupported_session_listing} =
             SessionInfo.normalize(%{session_id: "broken", pid: self(), token: "token"})

    assert {:ok, %SessionInfo{details: {:unavailable, :invalid_details}}} =
             SessionInfo.normalize(%{
               session_id: "registration",
               pid: self(),
               token: "token",
               metadata: struct!(MingaAgent.SessionMetadata, Map.put(metadata, :id, "other"))
             })

    assert {:ok, %SessionInfo{details: {:unavailable, :invalid_details}}} =
             SessionInfo.normalize(%{
               session_id: "registration",
               pid: self(),
               token: "token",
               metadata: Map.put(metadata, :id, "other")
             })
  end

  test "remote records expose only normalized unavailable reasons" do
    listing = SessionListing.unavailable("session", self(), :unreachable)

    assert %SessionInfo{details: {:unavailable, :unreachable}, metadata: nil} =
             SessionInfo.from_listing(listing, "token")

    assert {:error, :unsupported_session_listing} =
             SessionInfo.normalize(%{
               session_id: "session",
               pid: self(),
               token: "token",
               details: {:unavailable, {:noproc, {GenServer, :call, [self(), :metadata]}}}
             })
  end
end
