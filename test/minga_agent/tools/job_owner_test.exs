defmodule MingaAgent.Tools.JobOwnerTest do
  # Spawns shell OS processes via Shell.execute, which must not run async.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.Job
  alias MingaAgent.Tools.JobOwner

  # Real OS commands with wall-clock timeouts make these inherently slow.
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  setup do
    {:ok, owner} =
      start_supervised({JobOwner, session_id: "test-session", notify: self()})

    %{owner: owner}
  end

  describe "start_foreground/5" do
    test "runs a command and returns the output", %{owner: owner} do
      assert {:ok, output} = JobOwner.start_foreground(owner, "echo hello", "/tmp", 10)
      assert output =~ "hello"
    end

    test "returns output with exit code for command failure", %{owner: owner} do
      assert {:ok, output} = JobOwner.start_foreground(owner, "echo fail; exit 1", "/tmp", 10)
      assert output =~ "fail"
      assert output =~ "exit code: 1"
    end

    test "returns timeout error when command exceeds timeout", %{owner: owner} do
      assert {:error, {:incomplete, :timeout, _output}} =
               JobOwner.start_foreground(owner, "sleep 30", "/tmp", 1)
    end
  end

  describe "start_background/5" do
    test "returns a job id immediately", %{owner: owner} do
      assert {:ok, job_id} = JobOwner.start_background(owner, "echo hello", "/tmp", 10)
      assert is_binary(job_id)
      assert byte_size(job_id) > 0
    end

    test "sends a completion notification with exit code 0 to the notify pid", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "echo hello", "/tmp", 10)

      assert_receive {:job_completion, {^job_id, _gen, :completed, 0}}, 5_000
    end

    test "a nonzero exit fails the job and records the real exit code", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "echo PASS; exit 42", "/tmp", 10)

      assert_receive {:job_completion, {^job_id, _gen, :failed, 42}}, 5_000
    end

    test "rejects when too many concurrent jobs", %{owner: owner} do
      # Start 8 long-running jobs that block for a while
      for _i <- 1..8 do
        assert {:ok, _id} = JobOwner.start_background(owner, "sleep 60", "/tmp", 60)
      end

      # Give processes a moment to start (they should block on sleep 60)
      :sys.get_state(owner)

      assert {:error, :too_many_jobs} =
               JobOwner.start_background(owner, "echo overflow", "/tmp", 10)
    end
  end

  describe "job_status/2" do
    test "returns status for a live background job", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "sleep 30", "/tmp", 60)

      # Synchronize: the GenServer has processed the start
      :sys.get_state(owner)

      assert {:ok, %Job{} = job} = JobOwner.job_status(owner, job_id)
      assert job.id == job_id
      assert Job.live?(job)
    end

    test "returns status for a completed background job", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "echo done", "/tmp", 10)
      assert_receive {:job_completion, {^job_id, _gen, :completed, _code}}, 5_000

      assert {:ok, %Job{} = job} = JobOwner.job_status(owner, job_id)
      assert Job.finished?(job)
    end

    test "returns error for unknown job id", %{owner: owner} do
      assert {:error, :job_not_found} = JobOwner.job_status(owner, "nonexistent")
    end
  end

  describe "job_output/2" do
    test "returns output for a completed job", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "echo hello_world", "/tmp", 10)
      assert_receive {:job_completion, {^job_id, _gen, :completed, _code}}, 5_000

      assert {:ok, output} = JobOwner.job_output(owner, job_id)
      assert output =~ "hello_world"
    end

    test "returns error for a still-running job", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "sleep 30", "/tmp", 60)

      # Synchronize
      :sys.get_state(owner)

      assert {:error, :job_still_running} = JobOwner.job_output(owner, job_id)
    end

    test "returns error for unknown job id", %{owner: owner} do
      assert {:error, :job_not_found} = JobOwner.job_output(owner, "nonexistent")
    end
  end

  describe "cancel/2" do
    test "cancels a running background job", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "sleep 60", "/tmp", 60)

      # Synchronize
      :sys.get_state(owner)

      assert :ok = JobOwner.cancel(owner, job_id)

      assert {:ok, %Job{} = job} = JobOwner.job_status(owner, job_id)
      assert job.status == {:terminal, :cancelled}
    end

    test "returns error for already-terminal job", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "echo fast", "/tmp", 10)
      assert_receive {:job_completion, {^job_id, _gen, _outcome, _code}}, 5_000

      assert {:error, :already_terminal} = JobOwner.cancel(owner, job_id)
    end

    test "returns error for unknown job id", %{owner: owner} do
      assert {:error, :job_not_found} = JobOwner.cancel(owner, "nonexistent")
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

      {:ok, _job_id} =
        JobOwner.start_background(owner, "echo $$ > job.pid; exec sleep 60", dir, 60)

      os_pid = await(fn -> File.read(pid_file) end) |> String.trim()
      assert os_alive?(os_pid)

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1_000

      assert await(fn -> if os_alive?(os_pid), do: :error, else: {:ok, :gone} end) == :gone
    end
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

  describe "reap_all/1" do
    test "interrupts all running jobs", %{owner: owner} do
      {:ok, id1} = JobOwner.start_background(owner, "sleep 60", "/tmp", 60)
      {:ok, id2} = JobOwner.start_background(owner, "sleep 60", "/tmp", 60)

      # Synchronize
      :sys.get_state(owner)

      assert :ok = JobOwner.reap_all(owner)

      assert {:ok, %Job{status: :interrupted}} = JobOwner.job_status(owner, id1)
      assert {:ok, %Job{status: :interrupted}} = JobOwner.job_status(owner, id2)
    end

    test "allows new jobs after reaping", %{owner: owner} do
      for _i <- 1..8 do
        JobOwner.start_background(owner, "sleep 60", "/tmp", 60)
      end

      :sys.get_state(owner)

      assert {:error, :too_many_jobs} =
               JobOwner.start_background(owner, "echo x", "/tmp", 10)

      assert :ok = JobOwner.reap_all(owner)

      assert {:ok, _id} = JobOwner.start_background(owner, "echo y", "/tmp", 10)
    end
  end
end
