defmodule MingaAgent.SessionJobOwnerTest do
  # Starts real Session and JobOwner GenServers that share process state.
  use Minga.Test.SessionCase, async: false

  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Tools.JobOwner

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
      if observer = Keyword.get(opts, :observer), do: send(observer, :block_started)

      receive do
        :never_sent -> {:ok, ""}
      end
    end

    def shell(command, _cwd, _timeout_secs, opts) do
      Keyword.fetch!(opts, :on_exit_status).(3)
      {:ok, "ran #{command}"}
    end
  end

  @backend [process_backend: InstantBackend]

  defp spec(command, background? \\ false),
    do: %{command: command, cwd: "/tmp", background?: background?, timeout_secs: 30}

  defp start_session(opts \\ []),
    do: start_test_session([provider: Minga.Test.StubProvider, provider_opts: []] ++ opts)

  describe "admission" do
    test "admits a running job under the owner's epoch and returns the owner" do
      session = start_session()

      assert {:ok, %Record{id: "job-1", status: :running} = record, owner} =
               Session.admit_job(session, spec("make test"))

      assert is_pid(owner)
      assert {:ok, ^record} = Session.job(session, "job-1")
      assert Session.jobs(session) == [record]
    end

    test "refuses past the running limit with a typed error" do
      session = start_session()

      for _i <- 1..8, do: assert({:ok, _record, _owner} = Session.admit_job(session, spec("x")))

      assert {:error, {:job_limit, :session, 8}} = Session.admit_job(session, spec("x"))
    end

    test "refuses without a job owner" do
      session = start_session(start_job_owner?: false)
      assert {:error, :no_job_owner} = Session.admit_job(session, spec("make test"))
    end

    test "a caller that exits before starting its job cannot hold a running slot" do
      session = start_session()
      parent = self()

      {caller, ref} =
        spawn_monitor(fn ->
          send(parent, {:admitted, Session.admit_job(session, spec("make test"))})
        end)

      assert_receive {:admitted, {:ok, %Record{id: id}, _owner}}
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}

      assert eventually(fn ->
               match?(
                 {:ok, %Record{status: {:terminal, :cancelled, nil}}},
                 Session.job(session, id)
               )
             end)
    end
  end

  describe "caller exit" do
    test "killing a foreground caller cancels its running job" do
      session = start_session()
      parent = self()

      caller =
        spawn(fn ->
          {:ok, record, owner} = Session.admit_job(session, spec("block"))
          send(parent, {:admitted, record})
          JobOwner.start_foreground(owner, record, [observer: parent] ++ @backend)
        end)

      assert_receive {:admitted, %Record{id: id}}
      assert_receive :block_started

      Process.exit(caller, :kill)

      assert eventually(fn ->
               match?(
                 {:ok, %Record{status: {:terminal, :cancelled, nil}}},
                 Session.job(session, id)
               )
             end)

      assert {:ok, _record, _owner} = Session.admit_job(session, spec("x"))
    end
  end

  describe "settlement" do
    test "a foreground job settles with its exit code and owes no notice" do
      session = start_session()
      {:ok, record, owner} = Session.admit_job(session, spec("make test"))

      assert {:ok, "ran make test"} = JobOwner.start_foreground(owner, record, @backend)

      assert {:ok,
              %Record{status: {:terminal, :failed, 3}, preview: "ran make test", notice: :none}} =
               Session.job(session, record.id)
    end

    test "a background job settles with a pending notice shown at the turn boundary" do
      session = start_subscribed_session(Minga.Test.SessionMockProvider)
      {:ok, record, owner} = Session.admit_job(session, spec("make build", true))
      assert :ok = JobOwner.start_background(owner, record, @backend)

      assert eventually(fn ->
               match?({:ok, %Record{notice: :pending}}, Session.job(session, record.id))
             end)

      assert :ok = Session.send_prompt(session, "continue")
      await_turn_complete()

      assert {:system, "Background job job-1: failed (exit 3)", :info} in Session.messages(
               session
             )

      assert {:ok, %Record{notice: :delivered}} = Session.job(session, record.id)
    end

    test "a report from another epoch is ignored" do
      session = start_session()
      {:ok, %Record{id: id, epoch: epoch}, _owner} = Session.admit_job(session, spec("x"))
      output = %{reference: nil, preview: nil}

      send(session, {:job_settled, id, epoch + 1, :completed, 0, output})
      assert {:ok, %Record{status: :running}} = Session.job(session, id)

      send(session, {:job_settled, id, epoch, :completed, 0, output})
      assert {:ok, %Record{status: {:terminal, :completed, 0}}} = Session.job(session, id)
    end
  end

  describe "cancel_job/2" do
    test "cancels a running job through the owner" do
      session = start_session()
      {:ok, record, owner} = Session.admit_job(session, spec("block", true))
      assert :ok = JobOwner.start_background(owner, record, @backend)

      assert :ok = Session.cancel_job(session, record.id)

      assert {:ok, %Record{status: {:terminal, :cancelled, nil}, notice: :pending}} =
               Session.job(session, record.id)

      assert {:error, :already_terminal} = Session.cancel_job(session, record.id)
      assert {:error, :job_not_found} = Session.cancel_job(session, "job-99")
    end
  end

  describe "JobOwner death" do
    test "interrupts running jobs and serves the next job from a new owner and epoch" do
      session = start_session()
      {:ok, background, owner} = Session.admit_job(session, spec("block", true))
      assert :ok = JobOwner.start_background(owner, background, @backend)
      {:ok, foreground, ^owner} = Session.admit_job(session, spec("x"))

      Process.exit(owner, :kill)

      assert eventually(fn ->
               match?(
                 {:ok, %Record{status: {:interrupted, :owner_down}}},
                 Session.job(session, background.id)
               )
             end)

      assert {:ok, %Record{notice: :pending}} = Session.job(session, background.id)

      assert {:ok, %Record{status: {:interrupted, :owner_down}, notice: :none}} =
               Session.job(session, foreground.id)

      assert {:ok, next, new_owner} = Session.admit_job(session, spec("make test"))
      assert new_owner != owner
      assert next.epoch > background.epoch
      assert {:ok, "ran make test"} = JobOwner.start_foreground(new_owner, next, @backend)

      # A late terminal report cannot revive a job that was already interrupted.
      send(session, {:job_settled, background.id, background.epoch, :completed, 0, %{}})

      assert {:ok, %Record{status: {:interrupted, :owner_down}}} =
               Session.job(session, background.id)
    end
  end

  describe "teardown" do
    test "session stops its JobOwner when it terminates" do
      session = start_session()
      {:ok, _record, owner} = Session.admit_job(session, spec("x"))
      session_ref = Process.monitor(session)
      owner_ref = Process.monitor(owner)

      GenServer.stop(session, :normal)
      assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 5_000
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, 5_000
    end

    test "session terminates cleanly without a JobOwner" do
      session = start_session(start_job_owner?: false)
      ref = Process.monitor(session)

      GenServer.stop(session, :normal)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
    end
  end

  # Runtime-sent DOWN messages are not ordered behind a call, so poll the public query.
  @spec eventually((-> boolean()), non_neg_integer()) :: boolean()
  defp eventually(fun, attempts \\ 100)
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
