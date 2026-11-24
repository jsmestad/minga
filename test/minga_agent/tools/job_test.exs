defmodule MingaAgent.Tools.JobTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.Job

  @base_attrs [
    id: "test-job-1",
    session_id: "session-1",
    command: "echo hello",
    cwd: "/tmp",
    timeout_secs: 30,
    generation: 1,
    started_at: 1000
  ]

  describe "new/1" do
    test "creates a job in the starting state" do
      job = Job.new(@base_attrs)

      assert job.id == "test-job-1"
      assert job.session_id == "session-1"
      assert job.command == "echo hello"
      assert job.cwd == "/tmp"
      assert job.timeout_secs == 30
      assert job.generation == 1
      assert job.status == :starting
      assert job.background? == false
      assert job.exit_code == nil
      assert job.output_ref == nil
      assert job.finished_at == nil
    end

    test "creates a background job" do
      job = Job.new(Keyword.put(@base_attrs, :background?, true))

      assert job.background? == true
    end
  end

  describe "mark_running/1" do
    test "transitions starting to running" do
      job = Job.new(@base_attrs) |> Job.mark_running()

      assert job.status == :running
    end
  end

  describe "terminate/3" do
    test "transitions starting to terminal with outcome" do
      job = Job.new(@base_attrs) |> Job.terminate(:completed, 0)

      assert job.status == {:terminal, :completed}
      assert job.exit_code == 0
      assert job.finished_at != nil
    end

    test "transitions running to terminal with failure" do
      job =
        Job.new(@base_attrs)
        |> Job.mark_running()
        |> Job.terminate(:failed, 1)

      assert job.status == {:terminal, :failed}
      assert job.exit_code == 1
    end

    test "transitions running to terminal with timeout" do
      job =
        Job.new(@base_attrs)
        |> Job.mark_running()
        |> Job.terminate(:timeout, nil)

      assert job.status == {:terminal, :timeout}
      assert job.exit_code == nil
    end

    test "transitions running to terminal with cancellation" do
      job =
        Job.new(@base_attrs)
        |> Job.mark_running()
        |> Job.terminate(:cancelled, nil)

      assert job.status == {:terminal, :cancelled}
    end

    test "is idempotent on already-terminal jobs" do
      job =
        Job.new(@base_attrs)
        |> Job.terminate(:completed, 0)

      same = Job.terminate(job, :failed, 1)
      assert same.status == {:terminal, :completed}
      assert same.exit_code == 0
    end

    test "is idempotent on interrupted jobs" do
      job =
        Job.new(@base_attrs)
        |> Job.interrupt()

      same = Job.terminate(job, :completed, 0)
      assert same.status == :interrupted
    end
  end

  describe "set_output/3" do
    test "records output reference and text" do
      ref = make_ref()
      job = Job.new(@base_attrs) |> Job.set_output(ref, "hello world")

      assert job.output_ref == ref
      assert job.output_text == "hello world"
    end
  end

  describe "interrupt/1" do
    test "marks a starting job as interrupted" do
      job = Job.new(@base_attrs) |> Job.interrupt()

      assert job.status == :interrupted
      assert job.finished_at != nil
    end

    test "marks a running job as interrupted" do
      job = Job.new(@base_attrs) |> Job.mark_running() |> Job.interrupt()

      assert job.status == :interrupted
    end

    test "is idempotent on terminal jobs" do
      job =
        Job.new(@base_attrs)
        |> Job.terminate(:completed, 0)

      same = Job.interrupt(job)
      assert same.status == {:terminal, :completed}
    end

    test "is idempotent on already-interrupted jobs" do
      job = Job.new(@base_attrs) |> Job.interrupt()
      same = Job.interrupt(job)
      assert same.status == :interrupted
    end
  end

  describe "finished?/1" do
    test "returns false for starting jobs" do
      assert Job.finished?(Job.new(@base_attrs)) == false
    end

    test "returns false for running jobs" do
      assert Job.finished?(Job.new(@base_attrs) |> Job.mark_running()) == false
    end

    test "returns true for terminal jobs" do
      job = Job.new(@base_attrs) |> Job.terminate(:completed, 0)
      assert Job.finished?(job) == true
    end

    test "returns true for interrupted jobs" do
      job = Job.new(@base_attrs) |> Job.interrupt()
      assert Job.finished?(job) == true
    end
  end

  describe "live?/1" do
    test "returns true for starting and running" do
      assert Job.live?(Job.new(@base_attrs)) == true
      assert Job.live?(Job.new(@base_attrs) |> Job.mark_running()) == true
    end

    test "returns false for terminal and interrupted" do
      assert Job.live?(Job.new(@base_attrs) |> Job.terminate(:completed, 0)) == false
      assert Job.live?(Job.new(@base_attrs) |> Job.interrupt()) == false
    end
  end

  describe "outcome/1" do
    test "returns nil for live jobs" do
      assert Job.outcome(Job.new(@base_attrs)) == nil
    end

    test "returns the outcome for terminal jobs" do
      job = Job.new(@base_attrs) |> Job.terminate(:failed, 1)
      assert Job.outcome(job) == :failed
    end

    test "returns nil for interrupted jobs" do
      job = Job.new(@base_attrs) |> Job.interrupt()
      assert Job.outcome(job) == nil
    end
  end

  describe "summary_status/1" do
    test "returns the right status for each lifecycle state" do
      assert Job.summary_status(Job.new(@base_attrs)) == :starting
      assert Job.summary_status(Job.new(@base_attrs) |> Job.mark_running()) == :running

      assert Job.summary_status(Job.new(@base_attrs) |> Job.terminate(:completed, 0)) ==
               :completed

      assert Job.summary_status(Job.new(@base_attrs) |> Job.terminate(:failed, 1)) == :failed
      assert Job.summary_status(Job.new(@base_attrs) |> Job.terminate(:timeout, nil)) == :timeout

      assert Job.summary_status(Job.new(@base_attrs) |> Job.terminate(:cancelled, nil)) ==
               :cancelled

      assert Job.summary_status(Job.new(@base_attrs) |> Job.terminate(:crashed, nil)) == :crashed
      assert Job.summary_status(Job.new(@base_attrs) |> Job.interrupt()) == :interrupted
    end
  end
end
