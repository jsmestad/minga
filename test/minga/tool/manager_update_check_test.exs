defmodule Minga.Tool.ManagerUpdateCheckTest do
  use ExUnit.Case, async: false

  alias Minga.Events
  alias Minga.Tool.Manager
  alias Minga.Tool.Installer.Stub

  @moduletag timeout: 15_000
  # Exercises the singleton Manager with async update check tasks.
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  setup do
    Stub.reset()

    # Short per-check timeout for deterministic timeout tests
    prev_timeout = Application.get_env(:minga, :update_check_timeout)
    Application.put_env(:minga, :update_check_timeout, 500)

    # Subscribe to events before any action
    Events.subscribe(:tool_install_complete)
    Events.subscribe(:tool_install_failed)
    Events.subscribe(:tool_update_check_started)
    Events.subscribe(:tool_update_check_complete)

    # Clean up tools installed by previous tests
    for inst <- Manager.all_installed() do
      Manager.uninstall(inst.name)
    end

    Manager.cancel_update_check()

    on_exit(fn ->
      if prev_timeout do
        Application.put_env(:minga, :update_check_timeout, prev_timeout)
      else
        Application.delete_env(:minga, :update_check_timeout)
      end
    end)

    :ok
  end

  defp install_tool(name) do
    Stub.set_install_result({:ok, "1.0.0"})
    :ok = Manager.install(name)
    assert_receive {:minga_event, :tool_install_complete, %{name: ^name}}, 2_000
  end

  defp await_update_check(timeout \\ 5_000) do
    assert_receive {:minga_event, :tool_update_check_complete, payload}, timeout
    payload
  end

  describe "check_updates/0 returns promptly" do
    test "returns :ok without blocking on network calls" do
      install_tool(:pyright)
      gate_ref = Stub.gate_latest_versions()

      assert :ok = Manager.check_updates()
      assert_receive {:latest_version_blocked, ^gate_ref, worker_pid}, 2_000

      # Manager is responsive while check is blocked
      assert Manager.update_check_active?()
      assert is_list(Manager.tool_status_list())
      assert Manager.installed?(:pyright)

      Stub.release_latest_version(worker_pid, gate_ref)
      await_update_check()
    end
  end

  describe "responsiveness during update checks" do
    test "tool_status_list responds while checks are blocked" do
      install_tool(:gopls)
      install_tool(:pyright)
      gate_ref = Stub.gate_latest_versions()

      Manager.check_updates()

      # Collect blocked workers
      assert_receive {:latest_version_blocked, ^gate_ref, w1}, 2_000
      assert_receive {:latest_version_blocked, ^gate_ref, w2}, 2_000

      # Status queries still work
      statuses = Manager.tool_status_list()
      assert length(statuses) >= 2

      # Install queries still work
      assert Manager.installed?(:gopls)
      assert Manager.installed?(:pyright)

      # Installing new tools still works
      Stub.set_install_result({:ok, "1.0.0"})
      assert :ok = Manager.install(:stylua)
      assert_receive {:minga_event, :tool_install_complete, %{name: :stylua}}, 2_000

      Stub.release_latest_version(w1, gate_ref)
      Stub.release_latest_version(w2, gate_ref)
      # stylua was installed after the snapshot, so it may also be checked
      # depending on timing. Drain any extra blocked worker.
      receive do
        {:latest_version_blocked, ^gate_ref, w3} ->
          Stub.release_latest_version(w3, gate_ref)
      after
        200 -> :ok
      end

      await_update_check()
    end
  end

  describe "update result caching" do
    test "cached_updates returns results after check completes" do
      install_tool(:pyright)
      Stub.set_latest_version({:ok, "2.0.0"})

      Manager.check_updates()
      payload = await_update_check()

      assert [{:pyright, "1.0.0", "2.0.0"}] = payload.updates
      assert [] = payload.errors
      assert [{:pyright, "1.0.0", "2.0.0"}] = Manager.cached_updates()
    end

    test "tools at current version are not reported as updates" do
      install_tool(:pyright)
      Stub.set_latest_version({:ok, "1.0.0"})

      Manager.check_updates()
      payload = await_update_check()

      assert [] = payload.updates
      assert [] = Manager.cached_updates()
    end

    test "empty installed set completes immediately" do
      Manager.check_updates()
      payload = await_update_check()

      assert [] = payload.updates
      assert [] = payload.errors
    end
  end

  describe "concurrency bounds" do
    test "at most 4 update checks run simultaneously" do
      # Install 6 tools
      tools = [:pyright, :gopls, :black, :stylua, :clangd, :zls]
      for tool <- tools, do: install_tool(tool)

      gate_ref = Stub.gate_latest_versions()
      Manager.check_updates()

      # Exactly 4 workers should be blocked (max concurrency)
      workers =
        for _ <- 1..4 do
          assert_receive {:latest_version_blocked, ^gate_ref, pid}, 2_000
          pid
        end

      # 5th should not arrive yet (queued)
      refute_receive {:latest_version_blocked, ^gate_ref, _}, 200

      # Release one worker, the 5th should start
      Stub.release_latest_version(hd(workers), gate_ref)
      assert_receive {:latest_version_blocked, ^gate_ref, w5}, 2_000

      # Release another, the 6th should start
      Stub.release_latest_version(Enum.at(workers, 1), gate_ref)
      assert_receive {:latest_version_blocked, ^gate_ref, w6}, 2_000

      # Release remaining
      for w <- Enum.drop(workers, 2) ++ [w5, w6] do
        Stub.release_latest_version(w, gate_ref)
      end

      await_update_check()
      refute Manager.update_check_active?()
    end
  end

  describe "per-check timeouts" do
    test "timed-out checks report errors and do not block completion" do
      install_tool(:pyright)
      install_tool(:gopls)

      # Gate so checks never complete; the 500ms config timeout will fire
      _gate_ref = Stub.gate_latest_versions()

      Manager.check_updates()
      payload = await_update_check(5_000)

      # Both should time out
      assert length(payload.errors) == 2
      error_names = Enum.map(payload.errors, fn {name, _reason} -> name end)
      assert :pyright in error_names
      assert :gopls in error_names

      for {_name, reason} <- payload.errors do
        assert reason == "timeout"
      end

      # Manager is functional afterward
      refute Manager.update_check_active?()
      assert is_list(Manager.tool_status_list())
    end
  end

  describe "worker crash handling" do
    test "crashed update check worker reports error and completes" do
      install_tool(:pyright)
      Stub.set_latest_version_crash(true)

      Manager.check_updates()
      payload = await_update_check()

      assert [] = payload.updates
      assert [{:pyright, reason}] = payload.errors
      assert reason =~ "simulated crash"

      refute Manager.update_check_active?()
    end
  end

  describe "cancellation" do
    test "cancel_update_check stops in-flight checks" do
      install_tool(:pyright)
      gate_ref = Stub.gate_latest_versions()

      Manager.check_updates()
      assert_receive {:latest_version_blocked, ^gate_ref, _worker}, 2_000

      :ok = Manager.cancel_update_check()
      refute Manager.update_check_active?()

      # No complete event fires for the cancelled check
      refute_receive {:minga_event, :tool_update_check_complete, _}, 300
    end

    test "new check_updates cancels the previous in-flight check" do
      install_tool(:pyright)
      gate_ref = Stub.gate_latest_versions()

      Manager.check_updates()
      assert_receive {:latest_version_blocked, ^gate_ref, _worker1}, 2_000

      # Start event for the first check
      assert_receive {:minga_event, :tool_update_check_started, %{count: 1}}, 1_000

      # Second check cancels the first and starts fresh
      Manager.check_updates()
      assert_receive {:minga_event, :tool_update_check_started, %{count: 1}}, 1_000

      # A new worker appears for the second check
      assert_receive {:latest_version_blocked, ^gate_ref, worker2}, 2_000
      Stub.release_latest_version(worker2, gate_ref)

      payload = await_update_check()
      assert is_list(payload.updates)
    end
  end

  describe "stale completion" do
    test "result from cancelled generation does not update cache" do
      install_tool(:pyright)
      Stub.set_latest_version({:ok, "9.9.9"})

      gate_ref = Stub.gate_latest_versions()
      Manager.check_updates()
      assert_receive {:latest_version_blocked, ^gate_ref, _worker}, 2_000

      # Cancel the check before the result arrives.
      # Cancellation preserves the cache from any prior completed check,
      # so verify the stale 9.9.9 version never landed.
      Manager.cancel_update_check()
      cached_before = Manager.cached_updates()

      refute Enum.any?(cached_before, fn {name, _, latest} ->
               name == :pyright and latest == "9.9.9"
             end)

      # Start a new check with a different version
      Stub.ungate_latest_versions()
      Stub.set_latest_version({:ok, "3.0.0"})
      Manager.check_updates()
      payload = await_update_check()

      assert [{:pyright, "1.0.0", "3.0.0"}] = payload.updates
      assert [{:pyright, "1.0.0", "3.0.0"}] = Manager.cached_updates()
    end
  end

  describe "recovery after failures" do
    test "manager accepts new update checks after all workers fail" do
      install_tool(:pyright)

      # First check: crash
      Stub.set_latest_version_crash(true)
      Manager.check_updates()
      payload1 = await_update_check()
      assert length(payload1.errors) == 1

      # Second check: success
      Stub.set_latest_version_crash(false)
      Stub.set_latest_version({:ok, "2.0.0"})
      Manager.check_updates()
      payload2 = await_update_check()

      assert [{:pyright, "1.0.0", "2.0.0"}] = payload2.updates
      assert [] = payload2.errors
    end

    test "manager accepts new update checks after timeouts" do
      install_tool(:gopls)
      _gate_ref = Stub.gate_latest_versions()

      Manager.check_updates()
      payload1 = await_update_check(5_000)
      assert [{:gopls, "timeout"}] = payload1.errors

      # New check with ungated stub
      Stub.ungate_latest_versions()
      Stub.set_latest_version({:ok, "5.0.0"})
      Manager.check_updates()
      payload2 = await_update_check()

      assert [{:gopls, "1.0.0", "5.0.0"}] = payload2.updates
    end
  end
end
