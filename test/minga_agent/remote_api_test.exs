defmodule MingaAgent.RemoteAPITest do
  # RemoteAPI is fixed to the global SessionManager, so this test cannot isolate manager state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MingaAgent.DraftSnapshot
  alias MingaAgent.RemoteAPI
  alias MingaAgent.RemoteAPI.SessionInfo
  alias MingaAgent.Session
  alias MingaAgent.Session.Transcript.Entry
  alias MingaAgent.SessionListing
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionMetadata
  alias MingaAgent.SessionStore

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

  test "retained history requires the live session token and returns bounded original text", %{
    tmp_dir: dir
  } do
    assert {:ok, %SessionInfo{session_id: id, pid: pid, token: token}} =
             RemoteAPI.start_session(provider: Minga.Test.StubProvider, session_store_dir: dir)

    on_exit(fn -> SessionManager.stop_session(id) end)
    assert %{connection: %{target: target}} = Session.editor_snapshot(pid)
    :ok = Session.add_system_message(pid, "retained\noriginal 界")

    assert {:error, :unauthorized} =
             RemoteAPI.transcript_history_before(target, "invalid-token", target, :tail, 1)

    assert {:ok, _cursor, [%Entry{message: {:system, "retained\noriginal 界", :info}}], true} =
             RemoteAPI.transcript_history_before(target, token, target, :tail, 1)
  end

  test "only the current driver of the original Session can restore or replace its draft", %{
    tmp_dir: dir
  } do
    assert {:ok, %SessionInfo{session_id: id, pid: session, token: token}} =
             RemoteAPI.start_session(provider: Minga.Test.StubProvider, session_store_dir: dir)

    on_exit(fn -> SessionManager.stop_session(id) end)

    assert {:ok, %{role: :driver}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, first_receipt}
    first = {self(), first_receipt}
    draft = %DraftSnapshot{text: "Unsent 行", cursor: {0, 7}, attachments: [], paste_blocks: []}

    assert {:error, :unauthorized} =
             RemoteAPI.composer(id, "invalid-token", session, first, :read)

    assert {:error, :stale_target} = RemoteAPI.composer(id, token, self(), first, :read)
    assert {:ok, 0, nil} = RemoteAPI.composer(id, token, session, first, :read)

    assert {:error, :invalid_draft_operation} =
             RemoteAPI.composer(id, token, session, first, {:save, -1, draft})

    assert {:ok, 1} = RemoteAPI.composer(id, token, session, first, {:save, 0, draft})
    refute Enum.any?(Session.messages(session), &match?({:user, _}, &1))

    assert :ok = RemoteAPI.detach(id, token, first)

    assert {:ok, %{role: :driver}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, second_receipt}
    second = {self(), second_receipt}
    assert {:error, :not_driver} = RemoteAPI.composer(id, token, session, first, :read)

    assert {:error, :not_driver} =
             RemoteAPI.composer(id, token, session, first, {:save, 1, nil})

    assert {:ok, 1, ^draft} = RemoteAPI.composer(id, token, session, second, :read)
  end

  test "remote reattachment reconciles the exact durable queue receipt without resending", %{
    tmp_dir: dir
  } do
    assert {:ok, %SessionInfo{session_id: id, pid: session, token: token}} =
             RemoteAPI.start_session(
               provider: Minga.Test.SessionSlowMockProvider,
               session_store_dir: dir
             )

    on_exit(fn -> SessionManager.stop_session(id) end)

    assert {:ok, %{role: :driver}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, first_receipt}
    first = {self(), first_receipt}
    assert :ok = Session.send_prompt(session, "Hold the active turn")
    assert {:ok, {^id, request, sequence} = target} = Session.queue_target(session, id)

    text = "A queued follow-up"
    submission = String.duplicate("q", 24)
    draft = %DraftSnapshot{text: text, cursor: {0, 0}, attachments: [], paste_blocks: []}
    assert {:ok, 1} = RemoteAPI.composer(id, token, session, first, {:save, 0, draft})

    wrong =
      {:queue, {"other-record", request, sequence}, :follow_up, {1, submission, [], text}, text}

    assert {:error, :stale_target} = RemoteAPI.composer(id, token, session, first, wrong)
    assert {[], []} = Session.get_queued_messages(session)
    assert {:ok, 1, ^draft} = SessionStore.read_presentation(id, dir)

    op = {:queue, target, :follow_up, {1, submission, [], text}, text}

    assert {:ok, {^sequence, ^submission, :follow_up, 2} = receipt} =
             RemoteAPI.composer(id, token, session, first, op)

    assert :ok = RemoteAPI.detach(id, token, first)

    assert {:ok, %{role: :driver}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, renewed_receipt}
    renewed = {self(), renewed_receipt}
    reconcile = {:reconcile_queue, sequence, submission, 1}
    assert {:error, :not_driver} = RemoteAPI.composer(id, token, session, first, reconcile)
    assert {:ok, ^receipt} = RemoteAPI.composer(id, token, session, renewed, reconcile)

    confirm = {:confirm_queue_receipt, receipt}
    assert :ok = RemoteAPI.detach(id, token, renewed)
    assert {:error, :not_driver} = RemoteAPI.composer(id, token, session, renewed, confirm)
    assert {[], [^text]} = Session.get_queued_messages(session)

    assert {:ok, %{role: :driver}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, latest_receipt}
    latest = {self(), latest_receipt}
    assert {:ok, ^receipt} = RemoteAPI.composer(id, token, session, latest, reconcile)

    assert :ok = RemoteAPI.composer(id, token, session, latest, confirm)
    assert :ok = RemoteAPI.composer(id, token, session, latest, confirm)

    assert {:ok, 2, nil} = SessionStore.read_presentation(id, dir)
    assert {[], [^text]} = Session.get_queued_messages(session)

    assert {:error, :queue_receipt_unconfirmed} =
             RemoteAPI.composer(id, token, session, latest, reconcile)
  end

  test "ordinary remote send clears its saved draft before acknowledging and can be reconciled after reattach",
       %{tmp_dir: dir} do
    assert {:ok, %SessionInfo{session_id: id, pid: session, token: token}} =
             RemoteAPI.start_session(provider: Minga.Test.StubProvider, session_store_dir: dir)

    on_exit(fn -> SessionManager.stop_session(id) end)

    assert {:ok, %{role: :driver}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, receipt}
    authority = {self(), receipt}
    text = "A persistent composer draft"
    draft = %DraftSnapshot{text: text, cursor: {0, 0}, attachments: [], paste_blocks: []}
    submission_id = String.duplicate("a", 24)
    assert {:ok, 1} = RemoteAPI.composer(id, token, session, authority, {:save, 0, draft})

    assert {:ok, 2} =
             RemoteAPI.composer(
               id,
               token,
               session,
               authority,
               {:submit, 1, submission_id, [], text}
             )

    assert :ok = RemoteAPI.detach(id, token, authority)

    assert {:ok, %{role: :driver}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, new_receipt}
    renewed = {self(), new_receipt}
    assert {:ok, 2, nil} = RemoteAPI.composer(id, token, session, renewed, :read)

    assert {:admitted, 2} =
             RemoteAPI.composer(
               id,
               token,
               session,
               renewed,
               {:reconcile_submission, 1, submission_id}
             )

    assert {:error, :admission_unconfirmed} =
             RemoteAPI.composer(
               id,
               token,
               session,
               renewed,
               {:reconcile_submission, 1, String.duplicate("b", 24)}
             )

    refuted_id = String.duplicate("c", 24)
    assert {:ok, 3} = RemoteAPI.composer(id, token, session, renewed, {:save, 2, draft})

    assert {:not_admitted, 4} =
             RemoteAPI.composer(
               id,
               token,
               session,
               renewed,
               {:reconcile_submission, 3, refuted_id}
             )

    assert {:error, {:stale_draft_revision, 4}} =
             RemoteAPI.composer(id, token, session, renewed, {:submit, 3, refuted_id, [], text})

    assert {:ok, 4, ^draft} = RemoteAPI.composer(id, token, session, renewed, :read)

    assert Enum.count(Session.messages(session), &match?({:user, ^text}, &1)) == 1
  end

  test "an admitted remote prompt survives provider dispatch crash without disclosing the call",
       %{tmp_dir: dir} do
    assert {:ok, %SessionInfo{session_id: id, pid: session, token: token}} =
             RemoteAPI.start_session(
               provider: Minga.Test.StubProvider,
               provider_opts: [send_prompt_result: :raise_on_send],
               session_store_dir: dir
             )

    on_exit(fn -> SessionManager.stop_session(id) end)
    text = "private remote composer sentinel 723535"
    draft = %DraftSnapshot{text: text, cursor: {0, 0}, attachments: [], paste_blocks: []}
    submission_id = String.duplicate("d", 24)

    assert {:ok, %{role: :driver}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, receipt}
    authority = {self(), receipt}
    assert {:ok, 1} = RemoteAPI.composer(id, token, session, authority, {:save, 0, draft})

    log =
      capture_log(fn ->
        monitor = Process.monitor(session)

        assert {:error, {:remote_unavailable, {:remote_composer_failed, :error}}} =
                 RemoteAPI.composer(
                   id,
                   token,
                   session,
                   authority,
                   {:submit, 1, submission_id, [], text}
                 )

        assert_receive {:DOWN, ^monitor, :process, ^session, {:remote_composer_failed, :error}}
      end)

    assert log =~ "remote_composer"
    refute log =~ text
    refute log =~ inspect(receipt)
    assert {:ok, 2, nil} = SessionStore.read_presentation(id, dir)
    assert {:admitted, 2} = SessionStore.composer_admission(id, 1, submission_id, dir, [])
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
