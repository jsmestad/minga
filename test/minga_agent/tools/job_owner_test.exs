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

    test "sends a completion notification to the notify pid", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "echo hello", "/tmp", 10)

      assert_receive {:job_completion, {^job_id, _gen, :completed, _code}}, 5_000
    end

    test "reports completion for nonzero exit since Shell.execute wraps exit code in text", %{
      owner: owner
    } do
      {:ok, job_id} = JobOwner.start_background(owner, "exit 42", "/tmp", 10)

      # Shell.execute returns {:ok, text} for all exits; exit code is in the text.
      # The job outcome treats {:ok, _} as :completed.
      assert_receive {:job_completion, {^job_id, _gen, :completed, _code}}, 5_000
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

  describe "drain_completions/1" do
    test "returns and clears pending completions", %{owner: owner} do
      {:ok, job_id} = JobOwner.start_background(owner, "echo one", "/tmp", 10)
      assert_receive {:job_completion, {^job_id, _gen, :completed, _code}}, 5_000

      completions = JobOwner.drain_completions(owner)
      assert length(completions) >= 1
      assert Enum.any?(completions, fn {id, _gen, _outcome, _code} -> id == job_id end)

      # Second drain should be empty
      assert [] = JobOwner.drain_completions(owner)
    end
  end

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
