defmodule MingaAgent.SessionJobPersistenceTest do
  use Minga.Test.SessionCase, async: true

  alias MingaAgent.ArtifactStores
  alias MingaAgent.ArtifactSupervisor
  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tools.JobOwner

  @moduletag :tmp_dir

  # Runs jobs in the BEAM so these tests start no OS processes.
  defmodule InstantBackend do
    @moduledoc false
    @behaviour MingaAgent.Tools.ProcessBackend

    @impl true
    def find(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    def grep(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    def shell("block", _cwd, _timeout_secs, opts) do
      send(Keyword.fetch!(opts, :observer), {:block_started, self()})

      receive do
        :never_sent -> {:ok, ""}
      end
    end

    def shell("gated " <> _rest = command, _cwd, _timeout_secs, opts) do
      send(Keyword.fetch!(opts, :observer), {:gate, self()})

      receive do
        :release -> :ok
      end

      Keyword.fetch!(opts, :on_exit_status).(3)
      {:ok, "ran #{command}"}
    end

    def shell(command, _cwd, _timeout_secs, opts) do
      Keyword.fetch!(opts, :on_exit_status).(3)
      {:ok, "ran #{command}"}
    end
  end

  setup %{tmp_dir: dir} do
    %{dir: dir, runtime: start_artifact_runtime(Path.join(dir, "artifacts"))}
  end

  test "a background job that settled while idle is queryable after restart with its output",
       ctx do
    first = start_persistent_session(ctx)
    id = Session.session_id(first)
    {:ok, store} = ArtifactStores.ensure_record(id, ctx.runtime)

    {:ok, record, owner} = Session.admit_job(first, spec("gated build", true))
    assert :ok = JobOwner.start_background(owner, record, [observer: self()] ++ job_opts(store))
    assert_receive {:gate, task}

    # The job ends only after the admission was saved, so only the settle's own save records it.
    assert eventually(fn -> saved_status(ctx, id, record.id) == :running end)
    send(task, :release)
    assert eventually(fn -> saved_status(ctx, id, record.id) == {:terminal, :failed, 3} end)
    stop_session(first)

    second = start_persistent_session(ctx)
    {:ok, live, second_owner} = Session.admit_job(second, spec("block", true))

    assert :ok =
             JobOwner.start_background(second_owner, live, [observer: self()] ++ job_opts(nil))

    assert_receive {:block_started, _task}
    owner_ref = Process.monitor(second_owner)

    assert :ok = Session.load_session(second, id)

    # The replaced conversation's live job is reaped with its owner.
    assert_receive {:DOWN, ^owner_ref, :process, ^second_owner, _reason}, 5_000

    assert [
             %Record{
               id: job_id,
               status: {:terminal, :failed, 3},
               notice: :pending,
               output_ref: reference,
               preview: "ran gated build"
             }
           ] = Session.jobs(second)

    assert job_id == record.id
    {:ok, range} = Range.new(:full, :bytes, 0, reference.bytes, reference.bytes)
    context = Context.new(project_root: ctx.dir, artifact_store: store)
    assert {:ok, %{bytes: "ran gated build"}} = Context.fetch_output(context, reference, range)

    assert {:ok, %Record{id: "job-2"}, _owner} = Session.admit_job(second, spec("make test"))
  end

  test "a job running at save time loads interrupted for restart and is never rerun", ctx do
    first = start_persistent_session(ctx)
    id = Session.session_id(first)

    {:ok, record, owner} = Session.admit_job(first, spec("block", true))
    assert :ok = JobOwner.start_background(owner, record, [observer: self()] ++ job_opts(nil))
    assert_receive {:block_started, _task}

    assert eventually(fn -> saved_status(ctx, id, record.id) == :running end)
    stop_session(first)

    second = start_persistent_session(ctx)
    assert :ok = Session.load_session(second, id)

    assert {:ok,
            %Record{status: {:interrupted, :restart}, notice: :pending, finished_at: %DateTime{}}} =
             Session.job(second, record.id)

    assert Session.jobs(second) |> Enum.filter(&Record.running?/1) == []
    assert {:error, :already_terminal} = Session.cancel_job(second, record.id)
    refute_received {:block_started, _task}
  end

  test "new_session starts an empty ledger and reaps the discarded conversation's jobs", ctx do
    session = start_persistent_session(ctx)
    {:ok, record, owner} = Session.admit_job(session, spec("block", true))
    assert :ok = JobOwner.start_background(owner, record, [observer: self()] ++ job_opts(nil))
    assert_receive {:block_started, task}
    task_ref = Process.monitor(task)
    owner_ref = Process.monitor(owner)

    assert :ok = Session.new_session(session)

    assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}, 5_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, 5_000
    assert Session.jobs(session) == []

    assert {:ok, %Record{id: "job-1", epoch: epoch}, new_owner} =
             Session.admit_job(session, spec("make test"))

    assert new_owner != owner
    assert epoch > record.epoch
  end

  defp spec(command, background? \\ false),
    do: %{command: command, cwd: "/tmp", background?: background?, timeout_secs: 30}

  defp job_opts(store) do
    [
      process_backend: InstantBackend,
      artifact_store: store,
      capture_key: {:delivery, "checkpoint-1", "call-1"}
    ]
  end

  defp start_persistent_session(ctx) do
    start_test_session(
      provider: Minga.Test.SessionMockProvider,
      provider_opts: [],
      persist?: true,
      session_store_dir: ctx.dir,
      artifact_runtime: ctx.runtime
    )
  end

  # Terminate reaps live jobs without saving, as an application exit does.
  defp stop_session(session) do
    ref = Process.monitor(session)
    GenServer.stop(session, :normal)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
  end

  defp saved_status(ctx, session_id, job_id) do
    with {:ok, %{job_ledger: ledger}} <-
           SessionStore.load(session_id, ctx.dir, artifact_runtime: ctx.runtime),
         {:ok, %Record{status: status}} <- MingaAgent.Session.JobLedger.fetch(ledger, job_id) do
      status
    end
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

  # Saves are debounced timers and job reports come from other processes, so poll the public query.
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
