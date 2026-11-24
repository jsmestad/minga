defmodule MingaAgent.SessionJobNoticeTest do
  use Minga.Test.SessionCase, async: true

  alias MingaAgent.ArtifactSupervisor
  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Session.JobNotice
  alias MingaAgent.Tools.JobOwner
  alias Minga.Test.SessionContinuationProvider
  alias ReqLLM.Context

  @durable_timeout 30_000

  # Runs jobs in the BEAM so these tests start no OS processes.
  defmodule InstantBackend do
    @moduledoc false
    @behaviour MingaAgent.Tools.ProcessBackend

    @impl true
    def find(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    def grep(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    def shell("block", _cwd, _timeout_secs, _opts) do
      receive do
        :never_sent -> {:ok, ""}
      end
    end

    def shell(command, _cwd, _timeout_secs, opts) do
      Keyword.fetch!(opts, :on_exit_status).(3)
      {:ok, "ran #{command}"}
    end
  end

  describe "during an active turn" do
    @describetag :tmp_dir

    test "a job that ends mid-turn enters the next model call once", %{tmp_dir: dir} do
      session = start_native_session(dir)
      assert :ok = Session.set_tool_trust(session, "read_file", :session)
      assert :ok = Session.send_prompt(session, "read test.txt")

      assert_receive {:model_call, 0, worker, first}, @durable_timeout
      refute Enum.any?(first, &JobNotice.notice?/1)

      record = run_background(session, "make build")
      await_notice(session, record.id, :pending)
      send(worker, :proceed)

      assert_receive {:model_call, 1, worker, second}, @durable_timeout
      assert [notice] = Enum.filter(second, &JobNotice.notice?/1)
      assert notice.metadata.job_ids == [record.id]
      assert [^notice, %ReqLLM.Message{role: :tool} | _earlier] = Enum.reverse(second)
      assert {:ok, %Record{notice: :delivered}} = Session.job(session, record.id)
      send(worker, :proceed)

      # The turn ends with the notice already delivered, so no host request follows.
      await_idle(session)
      refute_receive {:model_call, 2, _worker, _messages}, 200
      assert notice_entries(session) == 1
      refute Enum.any?(Session.messages(session), &match?({:user, "Host notice" <> _}, &1))
    end

    test "a notice is held while an approval is outstanding and delivered after it resolves",
         %{tmp_dir: dir} do
      session = start_native_session(dir, approval: :all)
      assert :ok = Session.send_prompt(session, "read test.txt")
      assert_receive {:model_call, 0, worker, _first}, @durable_timeout
      send(worker, :proceed)

      assert_receive {:agent_event, ^session, {:approval_pending, %{target: target}}},
                     @durable_timeout

      record = run_background(session, "make build")
      await_notice(session, record.id, :pending)
      refute_received {:model_call, 1, _worker, _messages}

      assert :ok = Session.respond_to_approval(session, target, :approve)

      assert_receive {:model_call, 1, worker, second}, @durable_timeout
      assert [%{metadata: %{job_ids: [job_id]}}] = Enum.filter(second, &JobNotice.notice?/1)
      assert job_id == record.id
      send(worker, :proceed)
      await_idle(session)
      refute_receive {:model_call, 2, _worker, _messages}, 200
    end

    test "jobs that end before one boundary arrive as one batched message" do
      session = start_session()
      assert :ok = Session.send_prompt(session, "build it")
      assert_receive {:continuation_request, request}, @event_timeout

      first = run_background(session, "make build")
      second = run_background(session, "make test")
      await_notice(session, first.id, :pending)
      await_notice(session, second.id, :pending)

      complete(session, request, Enum.concat(request.messages, [Context.assistant("started")]))

      assert_receive {:continuation_request, host}, @event_timeout
      assert [notice] = Enum.filter(host.messages, &JobNotice.notice?/1)
      assert [^notice | _earlier] = Enum.reverse(host.messages)
      assert notice.metadata.job_ids == [first.id, second.id]
      assert notice_entries(session) == 1
    end
  end

  describe "while idle" do
    test "a job that ends starts a host request carrying its notice without a user prompt" do
      session = start_session()
      record = run_background(session, "make build")

      assert_receive {:continuation_request, request}, @event_timeout

      assert [%ReqLLM.Message{role: :system}, %ReqLLM.Message{role: :user} = notice] =
               request.messages

      assert notice.metadata == %{minga_origin: :job_notice, job_ids: [record.id]}

      assert [%{text: text}] = notice.content
      assert text =~ "Host notice (not from the user)"
      assert text =~ "Background job #{record.id} (`make build`) finished: failed, exit 3."

      messages = Session.messages(session)
      refute Enum.any?(messages, &(elem(&1, 0) == :user))
      assert notice_entries(session) == 1
      assert {:ok, %Record{notice: :delivered}} = Session.job(session, record.id)
      refute_receive {:continuation_request, _request}, 200
    end

    test "a failed turn holds the notice until the next turn ends" do
      session = start_session()
      assert :ok = Session.send_prompt(session, "build it")
      assert_receive {:continuation_request, _request}, @event_timeout
      send_provider_event(session, %Event.AgentStart{})
      send_provider_event(session, %Event.AgentEnd{})
      assert Session.status(session) == :error

      record = run_background(session, "make build")
      await_notice(session, record.id, :pending)
      refute_receive {:continuation_request, _request}, 200

      assert :ok = Session.send_prompt(session, "try again")
      assert_receive {:continuation_request, retry}, @event_timeout
      refute Enum.any?(retry.messages, &JobNotice.notice?/1)
      complete(session, retry, Enum.concat(retry.messages, [Context.assistant("retried")]))

      assert_receive {:continuation_request, host}, @event_timeout

      assert [%{metadata: %{job_ids: [job_id]}}] =
               Enum.filter(host.messages, &JobNotice.notice?/1)

      assert job_id == record.id
    end

    @tag :tmp_dir
    test "a delivered notice is not delivered again after save and load", %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      first = start_persistent_session(dir, runtime)
      id = Session.session_id(first)
      record = run_background(first, "make build")

      assert_receive {:continuation_request, request}, @event_timeout
      complete(first, request, Enum.concat(request.messages, [Context.assistant("noted")]))
      await_turn_complete()
      stop_session(first)

      second = start_persistent_session(dir, runtime)
      assert :ok = Session.load_session(second, id)
      assert {:ok, %Record{notice: :delivered}} = Session.job(second, record.id)
      refute_receive {:continuation_request, _request}, 200

      assert :ok = Session.send_prompt(second, "what happened?")
      assert_receive {:continuation_request, next}, @event_timeout
      assert Enum.count(next.messages, &JobNotice.notice?/1) == 1
    end

    @tag :tmp_dir
    test "delivery is saved with the host request before the turn ends", %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      first = start_persistent_session(dir, runtime)
      id = Session.session_id(first)
      record = run_background(first, "make build")

      # Stopping does not save, so only the admission's own write can record the delivery.
      assert_receive {:continuation_request, _request}, @event_timeout
      stop_session(first)

      second = start_persistent_session(dir, runtime)
      assert :ok = Session.load_session(second, id)
      assert {:ok, %Record{notice: :delivered}} = Session.job(second, record.id)
      refute_receive {:continuation_request, _request}, 200

      assert :ok = Session.send_prompt(second, "what happened?")
      assert_receive {:continuation_request, next}, @event_timeout
      assert Enum.count(next.messages, &JobNotice.notice?/1) == 1
    end

    @tag :tmp_dir
    test "a job interrupted by restart wakes the agent when the session loads, once",
         %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      first = start_persistent_session(dir, runtime)
      id = Session.session_id(first)
      record = run_background(first, "block")
      assert eventually(fn -> saved_status(dir, runtime, id, record.id) == :running end)
      stop_session(first)

      second = start_persistent_session(dir, runtime)
      assert :ok = Session.load_session(second, id)

      assert_receive {:continuation_request, request}, @event_timeout
      assert [notice] = Enum.filter(request.messages, &JobNotice.notice?/1)
      assert notice.metadata.job_ids == [record.id]
      assert [%{text: text}] = notice.content
      assert text =~ "Background job #{record.id} (`block`) was interrupted (restart)."
      assert {:ok, %Record{notice: :delivered}} = Session.job(second, record.id)
      stop_session(second)

      third = start_persistent_session(dir, runtime)
      assert :ok = Session.load_session(third, id)
      assert {:ok, %Record{notice: :delivered}} = Session.job(third, record.id)
      refute_receive {:continuation_request, _request}, 200
    end

    test "a refused notice request reports the failure and keeps the notices pending" do
      session = start_session(send_results: [{:error, :offline}])
      record = run_background(session, "make build")

      expected =
        "Could not deliver background job results to the agent: :offline. They will be retried at the next turn boundary."

      assert eventually(fn -> {:system, expected, :error} in Session.messages(session) end)
      assert Session.status(session) == :error
      assert {:ok, %Record{notice: :pending}} = Session.job(session, record.id)
      assert notice_entries(session) == 0

      # The next turn boundary delivers the notices, and the history holds them once.
      assert :ok = Session.send_prompt(session, "try again")
      assert_receive {:continuation_request, retry}, @event_timeout
      refute Enum.any?(retry.messages, &JobNotice.notice?/1)
      complete(session, retry, Enum.concat(retry.messages, [Context.assistant("retried")]))

      assert_receive {:continuation_request, host}, @event_timeout

      assert [%{metadata: %{job_ids: [job_id]}}] =
               Enum.filter(host.messages, &JobNotice.notice?/1)

      assert job_id == record.id
      assert {:ok, %Record{notice: :delivered}} = Session.job(session, record.id)
    end
  end

  defp start_session(provider_opts \\ []) do
    start_subscribed_session(
      SessionContinuationProvider,
      [test_pid: self(), system_prompt: "job notices"] ++ provider_opts
    )
  end

  defp saved_status(dir, runtime, session_id, job_id) do
    with {:ok, %{job_ledger: ledger}} <-
           SessionStore.load(session_id, dir, artifact_runtime: runtime),
         {:ok, %Record{status: status}} <- MingaAgent.Session.JobLedger.fetch(ledger, job_id) do
      status
    end
  end

  defp start_persistent_session(dir, runtime) do
    session =
      start_test_session(
        provider: SessionContinuationProvider,
        provider_opts: [test_pid: self(), system_prompt: "job notices"],
        persist?: true,
        session_store_dir: dir,
        artifact_runtime: runtime
      )

    Session.subscribe(session)
    session
  end

  defp run_background(session, command) do
    spec = %{command: command, cwd: "/tmp", background?: true, timeout_secs: 30}
    {:ok, record, owner} = Session.admit_job(session, spec)
    assert :ok = JobOwner.start_background(owner, record, process_backend: InstantBackend)
    record
  end

  defp complete(session, request, messages) do
    assert :ok =
             SessionContinuationProvider.complete(
               Session.get_provider(session),
               request,
               messages
             )
  end

  # Native calls the model through this client. Each call reports the exact messages it received and
  # waits for the test, so a job can end at a known point in the turn.
  defp start_native_session(dir, opts \\ []) do
    test_pid = self()
    calls = :counters.new(1, [:atomics])
    File.write!(Path.join(dir, "test.txt"), "file contents")
    oauth_path = Path.join(dir, "credentials/oauth.json")

    assert :ok =
             MingaAgent.OAuth.write_oauth_file(
               %{
                 access: "fixture-access",
                 refresh: "fixture-refresh",
                 account_id: "fixture-account",
                 expires: System.system_time(:millisecond) + 3_600_000
               },
               oauth_path
             )

    credential_opts = [
      config_dir: Path.join(dir, "credentials"),
      env: %{},
      oauth_path: oauth_path
    ]

    resolver_opts =
      MingaAgent.Test.ModelSelectionFixture.resolver_opts(model_id: "gpt-6.1-sol")
      |> Keyword.delete(:credential_snapshot)

    client = fn _model, messages, _opts ->
      call = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)
      send(test_pid, {:model_call, call, self(), messages})

      receive do
        :proceed -> build_stream_response(model_chunks(call))
      end
    end

    session =
      start_test_session(
        [
          provider: Native,
          persist?: true,
          session_store_dir: Path.join(dir, "sessions"),
          event_log_server:
            start_supervised!(
              {MingaAgent.EventLog,
               name: nil,
               db_dir: Path.join(dir, "events"),
               retention_sweep?: false,
               health_check: :none}
            ),
          artifact_runtime: start_artifact_runtime(Path.join(dir, "artifacts")),
          credentials_snapshot_fn: fn -> MingaAgent.Credentials.snapshot(credential_opts) end,
          provider_opts: [
            model: "openai:gpt-6.1-sol",
            model_resolver_opts: resolver_opts,
            credential_opts: credential_opts,
            project_root: dir,
            llm_client: client,
            tools: MingaAgent.Tools.all(project_root: dir),
            config: agent_config([])
          ]
        ] ++ approval_options(Keyword.get(opts, :approval))
      )

    assert :ok = Session.subscribe(session)
    session
  end

  defp model_chunks(0) do
    [
      ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{id: "tc_1", index: 0}),
      ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
    ]
  end

  defp model_chunks(_call) do
    [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
  end

  defp approval_options(nil), do: []

  defp approval_options(level) do
    events = :"job_notice_events_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: events})
    options = start_supervised!({Minga.Config.Options, name: nil, events_registry: events})
    assert {:ok, ^level} = Minga.Config.Options.set(options, :agent_tool_approval, level)
    [options_server: options]
  end

  defp await_idle(session) do
    assert_receive {:agent_event, ^session, {:status_changed, :idle}}, @durable_timeout
  end

  defp notice_entries(session) do
    Enum.count(Session.messages(session), fn
      {:system, "Background job " <> _rest, :info} -> true
      _other -> false
    end)
  end

  defp await_notice(session, job_id, expected) do
    assert eventually(fn ->
             match?({:ok, %Record{notice: ^expected}}, Session.job(session, job_id))
           end)
  end

  defp stop_session(session) do
    ref = Process.monitor(session)
    GenServer.stop(session, :normal)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
  end

  defp start_artifact_runtime(root) do
    suffix = System.unique_integer([:positive])

    opts = [
      name: Module.concat(__MODULE__, "ArtifactSupervisor#{suffix}"),
      root: root,
      quota: Module.concat(__MODULE__, "ArtifactQuota#{suffix}"),
      registry: Module.concat(__MODULE__, "ArtifactRegistry#{suffix}"),
      store_supervisor: Module.concat(__MODULE__, "ArtifactStores#{suffix}")
    ]

    start_supervised!(
      Supervisor.child_spec({ArtifactSupervisor, opts}, id: {:job_artifacts, suffix})
    )

    {:ok, runtime} = ArtifactSupervisor.runtime(opts)
    runtime
  end

  # Job reports come from the JobOwner process, so poll the public query.
  @spec eventually((-> boolean()), non_neg_integer()) :: boolean()
  defp eventually(fun, attempts \\ 300)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
