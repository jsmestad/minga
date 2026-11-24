defmodule MingaAgent.Tools.JobOwnerTest do
  # Spawns shell OS processes via Shell.execute, which must not run async.
  use ExUnit.Case, async: false

  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Tools.JobOwner

  # Real OS commands with wall-clock timeouts make these inherently slow.
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  @epoch 3

  defmodule CrashBackend do
    @moduledoc false
    @behaviour MingaAgent.Tools.ProcessBackend

    @impl true
    def find(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    def grep(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    def shell(_command, _cwd, _timeout_secs, _opts), do: exit(:backend_crashed)
  end

  setup do
    # The test process stands in for the Session and receives the owner's reports.
    owner = start_supervised!({JobOwner, session: self(), epoch: @epoch})
    %{owner: owner}
  end

  describe "start_foreground/3" do
    test "runs the job, returns the shell result, and reports start and end", %{owner: owner} do
      record = record("job-1", "echo hello")

      assert {:ok, output} = JobOwner.start_foreground(owner, record)
      assert output =~ "hello"

      assert_received {:job_started, "job-1", @epoch}
      assert_received {:job_settled, "job-1", @epoch, :completed, 0, %{preview: preview}}
      assert preview =~ "hello"
    end

    test "a nonzero exit settles as failed with the observed exit code", %{owner: owner} do
      record = record("job-1", "echo PASS; exit 42")

      assert {:ok, output} = JobOwner.start_foreground(owner, record)
      assert output =~ "PASS"
      assert_received {:job_settled, "job-1", @epoch, :failed, 42, _output}
    end

    test "a timeout settles as timeout without an exit code", %{owner: owner} do
      record = record("job-1", "sleep 30", timeout_secs: 1)

      assert {:error, {:incomplete, :timeout, _output}} = JobOwner.start_foreground(owner, record)
      assert_received {:job_settled, "job-1", @epoch, :timeout, nil, _output}
    end

    test "a crashed job task settles as crashed and errors the caller", %{owner: owner} do
      record = record("job-1", "ignored")

      assert {:error, message} =
               JobOwner.start_foreground(owner, record, process_backend: CrashBackend)

      assert message =~ "backend_crashed"
      assert_received {:job_settled, "job-1", @epoch, :crashed, nil, _output}
    end
  end

  describe "start_background/3" do
    test "returns once the task runs and reports its end later", %{owner: owner} do
      assert :ok =
               JobOwner.start_background(owner, record("job-1", "echo hello", background?: true))

      assert_received {:job_started, "job-1", @epoch}
      assert_receive {:job_settled, "job-1", @epoch, :completed, 0, _output}, 5_000
    end

    test "a nonzero exit fails the job and reports the real exit code", %{owner: owner} do
      record = record("job-1", "echo PASS; exit 42", background?: true)
      assert :ok = JobOwner.start_background(owner, record)

      assert_receive {:job_settled, "job-1", @epoch, :failed, 42, %{preview: preview}}, 5_000
      assert preview =~ "PASS"
    end
  end

  describe "start checks" do
    test "refuses a record admitted under another epoch", %{owner: owner} do
      stale = record("job-1", "echo never", epoch: @epoch - 1)

      assert {:error, :stale_epoch} = JobOwner.start_foreground(owner, stale)
      refute_received {:job_started, _id, _epoch}
    end

    test "refuses to run the same job id twice", %{owner: owner} do
      record = record("job-1", "sleep 60", background?: true, timeout_secs: 60)

      assert :ok = JobOwner.start_background(owner, record)
      assert {:error, :already_running} = JobOwner.start_background(owner, record)
    end
  end

  describe "cancel/2" do
    test "kills a running job and reports it cancelled", %{owner: owner} do
      record = record("job-1", "sleep 60", background?: true, timeout_secs: 60)
      assert :ok = JobOwner.start_background(owner, record)

      assert :ok = JobOwner.cancel(owner, "job-1")
      assert_received {:job_settled, "job-1", @epoch, :cancelled, nil, _output}
    end

    test "errors a waiting foreground caller when its job is cancelled", %{owner: owner} do
      record = record("job-1", "sleep 60", timeout_secs: 60)
      caller = Task.async(fn -> JobOwner.start_foreground(owner, record) end)
      assert_receive {:job_started, "job-1", @epoch}, 5_000

      assert :ok = JobOwner.cancel(owner, "job-1")
      assert {:error, "job cancelled"} = Task.await(caller)
    end

    test "returns not found for an ended or unknown job", %{owner: owner} do
      assert :ok =
               JobOwner.start_background(owner, record("job-1", "echo fast", background?: true))

      assert_receive {:job_settled, "job-1", @epoch, _outcome, _code, _output}, 5_000

      assert {:error, :job_not_found} = JobOwner.cancel(owner, "job-1")
      assert {:error, :job_not_found} = JobOwner.cancel(owner, "nonexistent")
    end

    test "a start that arrives after its cancel is refused and never runs", %{owner: owner} do
      assert {:error, :job_not_found} = JobOwner.cancel(owner, "job-1")

      assert {:error, :cancelled} =
               JobOwner.start_background(owner, record("job-1", "echo late", background?: true))

      refute_received {:job_started, "job-1", @epoch}
    end
  end

  describe "owner death" do
    @tag :tmp_dir
    test "a killed owner takes its running job's OS process with it", %{
      owner: owner,
      tmp_dir: dir
    } do
      dir = Path.expand(dir)
      pid_file = Path.join(dir, "job.pid")

      record =
        record("job-1", "echo $$ > job.pid; exec sleep 60",
          background?: true,
          cwd: dir,
          timeout_secs: 60
        )

      assert :ok = JobOwner.start_background(owner, record)

      os_pid = await(fn -> File.read(pid_file) end) |> String.trim()
      assert os_alive?(os_pid)

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1_000

      assert await(fn -> if os_alive?(os_pid), do: :error, else: {:ok, :gone} end) == :gone
    end
  end

  describe "reap_all/1" do
    test "kills running jobs without reporting ends and errors foreground callers", %{
      owner: owner
    } do
      assert :ok =
               JobOwner.start_background(
                 owner,
                 record("job-1", "sleep 60", background?: true, timeout_secs: 60)
               )

      foreground = record("job-2", "sleep 60", timeout_secs: 60)
      caller = Task.async(fn -> JobOwner.start_foreground(owner, foreground) end)
      assert_receive {:job_started, "job-2", @epoch}, 5_000

      assert :ok = JobOwner.reap_all(owner)
      assert {:error, :session_terminated} = Task.await(caller)
      refute_received {:job_settled, _id, _epoch, _outcome, _code, _output}

      # Reaped ids no longer occupy the owner.
      assert :ok =
               JobOwner.start_background(owner, record("job-1", "echo y", background?: true))
    end
  end

  defp record(id, command, opts \\ []) do
    spec = %{
      command: command,
      cwd: Keyword.get(opts, :cwd, "/tmp"),
      background?: Keyword.get(opts, :background?, false),
      timeout_secs: Keyword.get(opts, :timeout_secs, 10)
    }

    Record.admit(id, Keyword.get(opts, :epoch, @epoch), spec, DateTime.utc_now())
  end

  # The OS process ends asynchronously after its port closes, so poll its observable state.
  @spec await((-> {:ok, term()} | term()), non_neg_integer()) :: term()
  defp await(check, attempts \\ 100) do
    case check.() do
      {:ok, value} ->
        value

      _not_yet when attempts > 0 ->
        Process.sleep(50)
        await(check, attempts - 1)

      other ->
        flunk("condition not met: #{inspect(other)}")
    end
  end

  @spec os_alive?(String.t()) :: boolean()
  defp os_alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))
end
