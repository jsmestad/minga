defmodule MingaAgent.SessionJobOwnerTest do
  # Starts real Session and JobOwner GenServers that share process state.
  use Minga.Test.SessionCase, async: false

  describe "JobOwner lifecycle" do
    test "session starts a JobOwner by default" do
      session = start_test_session(provider: Minga.Test.StubProvider, provider_opts: [])
      state = :sys.get_state(session)

      assert is_pid(state.job_owner)
      assert Process.alive?(state.job_owner)
      assert is_reference(state.job_owner_ref)
      assert state.job_completions == []
    end

    test "session skips JobOwner when start_job_owner? is false" do
      session =
        start_test_session(
          provider: Minga.Test.StubProvider,
          provider_opts: [],
          start_job_owner?: false
        )

      state = :sys.get_state(session)

      assert state.job_owner == nil
      assert state.job_owner_ref == nil
    end

    test "job completions are buffered in session state" do
      session = start_test_session(provider: Minga.Test.StubProvider, provider_opts: [])
      completion = {"job-1", 1, :completed, 0}

      send(session, {:job_completion, completion})
      state = :sys.get_state(session)

      assert state.job_completions == [completion]
    end

    test "multiple completions accumulate in reverse arrival order" do
      session = start_test_session(provider: Minga.Test.StubProvider, provider_opts: [])

      send(session, {:job_completion, {"job-1", 1, :completed, 0}})
      send(session, {:job_completion, {"job-2", 2, :failed, 1}})
      state = :sys.get_state(session)

      assert [{"job-2", 2, :failed, 1}, {"job-1", 1, :completed, 0}] = state.job_completions
    end

    test "session clears job_owner on JobOwner crash" do
      session = start_test_session(provider: Minga.Test.StubProvider, provider_opts: [])
      state = :sys.get_state(session)
      job_owner = state.job_owner

      Process.exit(job_owner, :kill)

      # Poll until the DOWN message is processed.
      assert eventually(fn ->
               s = :sys.get_state(session)
               s.job_owner == nil and s.job_owner_ref == nil
             end)
    end

    test "session terminates cleanly with a running JobOwner" do
      session = start_test_session(provider: Minga.Test.StubProvider, provider_opts: [])
      state = :sys.get_state(session)
      job_owner = state.job_owner
      session_ref = Process.monitor(session)
      owner_ref = Process.monitor(job_owner)

      GenServer.stop(session, :normal)
      assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 5_000
      assert_receive {:DOWN, ^owner_ref, :process, ^job_owner, _reason}, 5_000
    end

    test "session terminates cleanly without a JobOwner" do
      session =
        start_test_session(
          provider: Minga.Test.StubProvider,
          provider_opts: [],
          start_job_owner?: false
        )

      ref = Process.monitor(session)
      GenServer.stop(session, :normal)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
    end
  end

  # Polls a predicate up to 50 times with :sys.get_state as the implicit barrier.
  @spec eventually((-> boolean()), non_neg_integer()) :: boolean()
  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      eventually(fun, attempts - 1)
    end
  end
end
