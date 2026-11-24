defmodule MingaAgent.SessionManagerChildLifecycleTest do
  use ExUnit.Case, async: true

  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle

  setup do
    session_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    name = :"child_lifecycle_manager_#{System.unique_integer([:positive])}"

    {:ok, manager} =
      SessionManager.start_link(
        name: name,
        session_supervisor: session_supervisor,
        child_limit: 3
      )

    Process.unlink(manager)

    on_exit(fn ->
      if Process.alive?(manager), do: GenServer.stop(manager)
    end)

    %{manager: manager}
  end

  @spec start_parent(GenServer.server()) :: {String.t(), pid()}
  defp start_parent(manager) do
    {:ok, session_id, pid} =
      SessionManager.start_session(manager,
        provider: Minga.Test.StubProvider,
        provider_opts: [],
        persist?: false
      )

    {session_id, pid}
  end

  @spec start_child(GenServer.server(), pid()) :: Handle.t()
  defp start_child(manager, parent_pid) do
    {:ok, handle} =
      SessionManager.start_background_subagent(
        manager,
        parent_pid,
        "child task",
        session_opts: [
          provider: Minga.Test.StubProvider,
          provider_opts: [],
          persist?: false
        ]
      )

    handle
  end

  describe "no-grandchild policy" do
    test "rejects a grandchild request from a session that is itself a background subagent", %{
      manager: manager
    } do
      {_parent_id, parent_pid} = start_parent(manager)
      child_handle = start_child(manager, parent_pid)

      assert {:error, :grandchild_not_allowed} =
               SessionManager.start_background_subagent(
                 manager,
                 child_handle.pid,
                 "grandchild task",
                 session_opts: [
                   provider: Minga.Test.StubProvider,
                   provider_opts: [],
                   persist?: false
                 ]
               )
    end

    test "allows a child from a session that is not itself a background subagent", %{
      manager: manager
    } do
      {_parent_id, parent_pid} = start_parent(manager)

      assert {:ok, %Handle{}} =
               SessionManager.start_background_subagent(
                 manager,
                 parent_pid,
                 "child task",
                 session_opts: [
                   provider: Minga.Test.StubProvider,
                   provider_opts: [],
                   persist?: false
                 ]
               )
    end
  end

  describe "per-parent child limit" do
    test "rejects a child when the running child count reaches the limit", %{manager: manager} do
      {_parent_id, parent_pid} = start_parent(manager)

      # Start children up to the limit (3 in this test setup).
      for _ <- 1..3 do
        start_child(manager, parent_pid)
      end

      assert {:error, :child_limit_reached} =
               SessionManager.start_background_subagent(
                 manager,
                 parent_pid,
                 "one too many",
                 session_opts: [
                   provider: Minga.Test.StubProvider,
                   provider_opts: [],
                   persist?: false
                 ]
               )
    end

    test "does not count completed children toward the limit", %{manager: manager} do
      {_parent_id, parent_pid} = start_parent(manager)

      handles =
        for _ <- 1..3 do
          start_child(manager, parent_pid)
        end

      # Stop the first child so it transitions to completed.
      first_child = hd(handles)
      ref = Process.monitor(first_child.pid)
      SessionManager.stop_session(manager, first_child.session_id)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
      :sys.get_state(manager)

      # Now a new child should be allowed since only 2 are running.
      assert {:ok, %Handle{}} =
               SessionManager.start_background_subagent(
                 manager,
                 parent_pid,
                 "replacement child",
                 session_opts: [
                   provider: Minga.Test.StubProvider,
                   provider_opts: [],
                   persist?: false
                 ]
               )
    end

    test "allows children from different parents independently", %{manager: manager} do
      {_parent_id1, parent_pid1} = start_parent(manager)
      {_parent_id2, parent_pid2} = start_parent(manager)

      for _ <- 1..3 do
        start_child(manager, parent_pid1)
      end

      # Second parent should still be able to start children.
      assert {:ok, %Handle{}} =
               SessionManager.start_background_subagent(
                 manager,
                 parent_pid2,
                 "second parent child",
                 session_opts: [
                   provider: Minga.Test.StubProvider,
                   provider_opts: [],
                   persist?: false
                 ]
               )
    end
  end

  describe "child completion notification" do
    test "a stopped child settles as cancelled and keeps its result", %{
      manager: manager
    } do
      # Use self() as the parent so we can receive the notification.
      # We need a real session though, so start one and then start a child of it.
      {_parent_id, parent_pid} = start_parent(manager)
      child_handle = start_child(manager, parent_pid)

      child_ref = Process.monitor(child_handle.pid)
      SessionManager.stop_session(manager, child_handle.session_id)
      assert_receive {:DOWN, ^child_ref, :process, _, _}, 1_000

      # The parent session pid receives the message, not us.
      # We need to verify through state instead. Let's check the handle status.
      :sys.get_state(manager)

      assert {:ok, %Handle{status: :cancelled, result: "cancelled"} = completed_handle} =
               SessionManager.get_child_result(manager, child_handle.session_id)

      assert completed_handle.completed_at != nil
    end

    test "the parent receives {:child_agent_completed, handle} when a child is stopped", %{
      manager: manager
    } do
      {_parent_id, parent_pid} = start_parent(manager)
      child_handle = start_child(manager, parent_pid)
      test_pid = self()

      # Replace the child's parent_pid to our test process so we receive the message directly.
      :sys.replace_state(manager, fn state ->
        Map.update!(state, :background_subagents, fn subs ->
          Map.update!(subs, child_handle.session_id, fn handle ->
            %{handle | parent_pid: test_pid}
          end)
        end)
      end)

      child_ref = Process.monitor(child_handle.pid)
      SessionManager.stop_session(manager, child_handle.session_id)
      assert_receive {:DOWN, ^child_ref, :process, _, _}, 1_000
      # Synchronize with the manager to ensure it has processed the DOWN.
      :sys.get_state(manager)

      assert_receive {:child_agent_completed, %Handle{status: :cancelled} = handle}, 1_000
      assert handle.session_id == child_handle.session_id
      assert handle.result == "cancelled"
      assert handle.completed_at != nil
    end

    test "child crash sends failure notification with :failed status", %{manager: manager} do
      {_parent_id, parent_pid} = start_parent(manager)

      {:ok, child_handle} =
        SessionManager.start_background_subagent(
          manager,
          parent_pid,
          "crash me",
          session_opts: [
            provider: Minga.Test.StubProvider,
            provider_opts: [],
            persist?: false,
            restart_max_attempts: 0,
            restart_window_ms: 0
          ]
        )

      test_pid = self()

      # Replace the child's parent_pid to our test process so we receive the notification.
      :sys.replace_state(manager, fn state ->
        Map.update!(state, :background_subagents, fn subs ->
          Map.update!(subs, child_handle.session_id, fn handle ->
            %{handle | parent_pid: test_pid}
          end)
        end)
      end)

      child_ref = Process.monitor(child_handle.pid)
      Process.exit(child_handle.pid, :kill)
      assert_receive {:DOWN, ^child_ref, :process, _, :killed}, 1_000
      # Synchronize with the manager to ensure it has processed the DOWN.
      :sys.get_state(manager)

      assert_receive {:child_agent_completed, %Handle{status: :failed} = handle}, 5_000
      assert handle.session_id == child_handle.session_id
      assert handle.result =~ "restart_exhausted"
      assert handle.completed_at != nil
    end
  end

  describe "stopping a child during restart backoff" do
    test "settles the child as cancelled instead of losing it", %{manager: manager} do
      {_parent_id, parent_pid} = start_parent(manager)

      {:ok, child} =
        SessionManager.start_background_subagent(manager, parent_pid, "child task",
          session_opts: [
            provider: Minga.Test.StubProvider,
            provider_opts: [],
            persist?: false,
            restart_backoff_base_ms: 120_000,
            restart_backoff_max_ms: 120_000
          ]
        )

      ref = Process.monitor(child.pid)
      Process.exit(child.pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}, 1_000
      await_restart_backoff(manager, child.session_id)

      assert :ok = SessionManager.stop_session(manager, child.session_id)

      assert {:ok, %Handle{status: :cancelled, completed_at: %DateTime{}}} =
               SessionManager.get_child_result(manager, child.session_id)
    end
  end

  # The manager handles the child's DOWN on its own schedule, so poll until it has no live pid.
  @spec await_restart_backoff(GenServer.server(), String.t(), non_neg_integer()) :: :ok
  defp await_restart_backoff(manager, session_id, attempts \\ 100) do
    case SessionManager.get_session(manager, session_id) do
      {:error, :not_found} ->
        :ok

      {:ok, _pid} when attempts > 0 ->
        Process.sleep(10)
        await_restart_backoff(manager, session_id, attempts - 1)
    end
  end

  describe "get_child_result/2" do
    test "returns {:ok, handle} for a known background subagent", %{manager: manager} do
      {_parent_id, parent_pid} = start_parent(manager)
      child_handle = start_child(manager, parent_pid)

      assert {:ok, %Handle{session_id: session_id}} =
               SessionManager.get_child_result(manager, child_handle.session_id)

      assert session_id == child_handle.session_id
    end

    test "returns {:error, :not_found} for an unknown session ID", %{manager: manager} do
      assert {:error, :not_found} = SessionManager.get_child_result(manager, "nonexistent")
    end

    test "returns the cancelled handle after a child is stopped", %{manager: manager} do
      {_parent_id, parent_pid} = start_parent(manager)
      child_handle = start_child(manager, parent_pid)

      child_ref = Process.monitor(child_handle.pid)
      SessionManager.stop_session(manager, child_handle.session_id)
      assert_receive {:DOWN, ^child_ref, :process, _, _}, 1_000
      :sys.get_state(manager)

      assert {:ok, %Handle{status: :cancelled, result: "cancelled"} = handle} =
               SessionManager.get_child_result(manager, child_handle.session_id)

      assert handle.completed_at != nil
    end
  end

  describe "generation tracking" do
    test "new handles start at generation 1", %{manager: manager} do
      {_parent_id, parent_pid} = start_parent(manager)
      child_handle = start_child(manager, parent_pid)

      assert {:ok, %Handle{generation: 1}} =
               SessionManager.get_child_result(manager, child_handle.session_id)
    end
  end

  describe "worktree metadata on handle" do
    test "handle stores worktree path and base SHA", %{manager: manager} do
      {_parent_id, parent_pid} = start_parent(manager)

      {:ok, handle} =
        SessionManager.start_background_subagent(
          manager,
          parent_pid,
          "worktree child",
          session_opts: [
            provider: Minga.Test.StubProvider,
            provider_opts: [],
            persist?: false
          ],
          worktree_path: "/tmp/fake-worktree",
          worktree_base_sha: "abc123"
        )

      assert handle.worktree_path == "/tmp/fake-worktree"
      assert handle.worktree_base_sha == "abc123"
    end

    test "handle without worktree has nil path and SHA", %{manager: manager} do
      {_parent_id, parent_pid} = start_parent(manager)
      child_handle = start_child(manager, parent_pid)

      assert child_handle.worktree_path == nil
      assert child_handle.worktree_base_sha == nil
    end
  end

  describe "Handle transitions" do
    test "interrupt/2 marks a running handle as interrupted" do
      handle =
        Handle.new(
          session_id: "test-1",
          pid: self(),
          task: "test task",
          started_at: DateTime.utc_now()
        )

      interrupted = Handle.interrupt(handle, :lost_during_restart)
      assert interrupted.status == :interrupted
      assert interrupted.result =~ "lost_during_restart"
      assert %DateTime{} = interrupted.completed_at
    end

    test "next_generation/1 increments the generation counter" do
      handle =
        Handle.new(
          session_id: "test-1",
          pid: self(),
          task: "test task",
          started_at: DateTime.utc_now()
        )

      assert handle.generation == 1
      bumped = Handle.next_generation(handle)
      assert bumped.generation == 2
      assert Handle.next_generation(bumped).generation == 3
    end

    test "complete/2 only transitions from :running" do
      handle =
        Handle.new(
          session_id: "test-1",
          pid: self(),
          task: "test task",
          started_at: DateTime.utc_now()
        )

      completed = Handle.complete(handle, "done")
      assert completed.status == :completed

      assert_raise FunctionClauseError, fn ->
        Handle.complete(opaque(completed), "again")
      end
    end

    test "with_worktree/3 sets worktree metadata" do
      handle =
        Handle.new(
          session_id: "test-1",
          pid: self(),
          task: "test task",
          started_at: DateTime.utc_now()
        )

      updated = Handle.with_worktree(handle, "/tmp/wt", "deadbeef")
      assert updated.worktree_path == "/tmp/wt"
      assert updated.worktree_base_sha == "deadbeef"
    end

    test "with_changes/2 records change manifest" do
      handle =
        Handle.new(
          session_id: "test-1",
          pid: self(),
          task: "test task",
          started_at: DateTime.utc_now()
        )

      changes = [{:added, "lib/new.ex"}, {:modified, "lib/old.ex"}, {:deleted, "lib/gone.ex"}]
      updated = Handle.with_changes(handle, changes)
      assert updated.changes == changes
    end

    test "fail/2 only transitions from :running" do
      handle =
        Handle.new(
          session_id: "test-1",
          pid: self(),
          task: "test task",
          started_at: DateTime.utc_now()
        )

      failed = Handle.fail(handle, :crash)
      assert failed.status == :failed

      assert_raise FunctionClauseError, fn ->
        Handle.fail(opaque(failed), :crash_again)
      end
    end
  end

  @spec opaque(Handle.t()) :: Handle.t()
  defp opaque(handle), do: handle
end
