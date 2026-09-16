defmodule Minga.MacOSNativeIPCHelperIntegrationTest do
  @moduledoc """
  Runs the packaged Swift helper against the real Elixir AF_UNIX server.

  This suite is opt-in because it requires macOS and an Xcode-built Minga.app.
  """

  # Not async: the production endpoint has one fixed Darwin runtime directory.
  use ExUnit.Case, async: false

  @moduletag :macos_ipc_helper

  @helper_timeout 10_000

  alias MingaEditor.NativeIPC.Supervisor, as: IPCSupervisor
  alias MingaEditor.NativeIPC.OperationNativeResult
  alias MingaEditor.NativeIPC.OperationReceipt.Evidence
  alias MingaEditor.NativeIPC.Server
  alias Minga.Frontend.WaitRequests

  setup do
    helper = System.fetch_env!("MINGA_IPC_HELPER")
    assert File.exists?(helper)

    {runtime_parent, 0} = System.cmd("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"])
    runtime_parent = runtime_parent |> String.trim() |> Path.expand()
    runtime_dir = Path.join(runtime_parent, "com.minga.editor")

    case File.ls(runtime_dir) do
      {:error, :enoent} ->
        :ok

      {:ok, []} ->
        :ok

      {:ok, entries} ->
        flunk("refusing to replace an active native IPC directory: #{inspect(entries)}")

      {:error, reason} ->
        flunk("cannot inspect native IPC directory: #{inspect(reason)}")
    end

    suffix = System.unique_integer([:positive, :monotonic])
    registry = Module.concat(__MODULE__, "Events#{suffix}")
    tasks = Module.concat(__MODULE__, "Tasks#{suffix}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    tracker = start_supervised!({WaitRequests, name: nil, events_registry: registry})

    buffer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    owner = self()

    open_wait = fn path, editor_mode?, request_id, waiter, _editor, wait_tracker ->
      if String.ends_with?(path, "before-acceptance.txt") do
        send(owner, {:opened, path, editor_mode?, request_id, self()})

        receive do
          {:continue_open, ^request_id} -> :ok
        after
          5_000 -> raise "timed out waiting to release pre-acceptance IPC test"
        end

        WaitRequests.register(buffer, path, request_id, waiter, wait_tracker)
      else
        :ok = WaitRequests.register(buffer, path, request_id, waiter, wait_tracker)
        send(owner, {:opened, path, editor_mode?, request_id, self()})
        :ok
      end
    end

    open_receipt = fn path, editor_mode?, receipt, receipt_server, _editor ->
      send(owner, {:receipt_opened, path, editor_mode?, receipt, receipt_server})
      :ok
    end

    inspect_request = fn identity, continuation, choice_limit, _editor ->
      send(owner, {:inspected, continuation, choice_limit})

      {:ok,
       %{
         "version" => 1,
         "type" => "inspection",
         "app_instance_id" => identity.app_instance_id,
         "core_instance_id" => identity.core_instance_id,
         "revision" => "19",
         "authoritative" => %{
           "active_tab_id" => 7,
           "active_pane_id" => 11,
           "tabs" => []
         },
         "presented" => %{"status" => "committed_not_native_observed"}
       }}
    end

    navigation_request = fn identity, command, receipt, receipt_server, _editor ->
      send(owner, {:navigated, identity, command, receipt})
      {:ok, _applied} = Server.operation_applied(receipt_server, receipt.operation_id, 11, 20)
      Server.finish_operation(receipt_server, receipt.operation_id, :applied)
    end

    sleeper =
      Port.open({:spawn_executable, ~c"/bin/sleep"}, [
        :binary,
        :exit_status,
        args: [~c"60"]
      ])

    {:os_pid, app_pid} = Port.info(sleeper, :os_pid)
    euid = File.stat!(File.cwd!()).uid

    start_supervised!(
      {IPCSupervisor,
       name: nil,
       server_name: nil,
       task_supervisor_name: tasks,
       runtime_parent: runtime_parent,
       runtime_dir: runtime_dir,
       app_instance_id: "app-instance-integration",
       app_pid: app_pid,
       euid: euid,
       launch_nonce: "integration-launch-nonce",
       wait_tracker: tracker,
       open_wait: open_wait,
       open_receipt: open_receipt,
       inspect_request: inspect_request,
       navigation_request: navigation_request,
       kill_checker: fn ^app_pid -> true end}
    )

    on_exit(fn ->
      send(buffer, :stop)

      try do
        Port.close(sleeper)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf!(runtime_dir)
    end)

    descriptor = runtime_dir |> Path.join("current.json") |> File.read!() |> JSON.decode!()

    %{
      app_pid: app_pid,
      buffer: buffer,
      descriptor: descriptor,
      helper: helper,
      runtime_parent: runtime_parent,
      tracker: tracker
    }
  end

  test "packaged helper probes the exact confstr-backed endpoint", ctx do
    assert {_, 0} = run_helper(ctx.helper, ["probe"])

    descriptor =
      ctx.runtime_parent
      |> Path.join("com.minga.editor/current.json")
      |> File.read!()
      |> JSON.decode!()

    assert Path.dirname(descriptor["socket_path"]) ==
             Path.join(ctx.runtime_parent, "com.minga.editor")
  end

  test "packaged helper fails closed or reconnects explicitly on nonce conflict", ctx do
    assert {_, 1} =
             run_helper(ctx.helper, ["probe", "--expected-launch-nonce", "different-nonce"])

    assert {_, 0} =
             run_helper(ctx.helper, [
               "probe",
               "--expected-launch-nonce",
               "different-nonce",
               "--allow-launch-conflict"
             ])
  end

  test "packaged helper exposes finite capabilities and bounded inspection", ctx do
    assert {capabilities_output, 0} = run_helper(ctx.helper, ["capabilities"])
    capabilities = JSON.decode!(capabilities_output)
    assert capabilities["type"] == "capabilities"
    assert "goto_location" in capabilities["commands"]
    assert capabilities["limits"]["maximum_frame_bytes"] == 65_536

    assert {inspection_output, 0} =
             run_helper(ctx.helper, ["inspect", "--continuation=page-token", "--choice-limit=9"])

    inspection = JSON.decode!(inspection_output)
    assert inspection["type"] == "inspection"
    assert inspection["revision"] == "19"
    assert inspection["authoritative"]["active_pane_id"] == 11
    assert_receive {:inspected, "page-token", 9}
  end

  test "packaged helper submits an exact semantic target and returns its receipt", ctx do
    args = [
      "select-tab",
      "--app-instance-id=#{ctx.descriptor["app_instance_id"]}",
      "--core-instance-id=#{ctx.descriptor["core_instance_id"]}",
      "--target-token=12345",
      "--tab-id=7",
      "--deadline-ms=1000"
    ]

    assert {output, 0} = run_helper(ctx.helper, args)
    result = JSON.decode!(output)
    assert result["type"] == "completed"
    assert result["receipt"]["kind"] == "select_tab"
    assert result["receipt"]["outcome"] == "applied"
    assert result["receipt"]["target"]["tab_id"] == 7

    assert_receive {:navigated, identity, command, receipt}
    assert identity.app_instance_id == ctx.descriptor["app_instance_id"]
    assert identity.core_instance_id == ctx.descriptor["core_instance_id"]
    assert command.kind == :select_tab
    assert command.target_token == 12_345
    assert receipt.operation_id |> Integer.to_string() == result["receipt"]["operation_id"]
  end

  test "packaged wait observes acceptance, completion, and acknowledgement", ctx do
    target = Path.join(ctx.runtime_parent, "minga-ipc-helper-completion.txt")
    task = Task.async(fn -> run_helper(ctx.helper, ["wait", target]) end)

    assert_receive {:opened, ^target, false, request_id, _handler}, 2_000
    assert is_binary(request_id)
    assert :ok = WaitRequests.accept(ctx.buffer, target, ctx.tracker)
    assert {_, 0} = Task.await(task, @helper_timeout)
    assert :ok = WaitRequests.await_acknowledgements(1_000, ctx.tracker)
  end

  test "packaged wait fails when the BEAM endpoint disconnects", ctx do
    target = Path.join(ctx.runtime_parent, "minga-ipc-helper-disconnect.txt")
    task = Task.async(fn -> run_helper(ctx.helper, ["wait", target]) end)

    assert_receive {:opened, ^target, false, _request_id, _handler}, 2_000
    assert Task.yield(task, 100) == nil
    assert :ok = stop_supervised(IPCSupervisor)
    assert {output, 1} = Task.await(task, @helper_timeout)
    assert output =~ "disconnected"
  end

  test "packaged wait returns retryable status when endpoint dies before acceptance", ctx do
    target = Path.join(ctx.runtime_parent, "endpoint-before-acceptance.txt")
    task = Task.async(fn -> run_helper(ctx.helper, ["wait", target]) end)

    assert_receive {:opened, ^target, false, _request_id, _handler}, 2_000
    assert Task.yield(task, 100) == nil
    assert :ok = stop_supervised(IPCSupervisor)
    assert {output, 5} = Task.await(task, @helper_timeout)
    assert output =~ "before accepting"
  end

  test "packaged wait returns retryable status when app dies before acceptance", ctx do
    target = Path.join(ctx.runtime_parent, "before-acceptance.txt")
    task = Task.async(fn -> run_helper(ctx.helper, ["wait", target]) end)

    assert_receive {:opened, ^target, false, request_id, handler}, 2_000
    assert Task.yield(task, 100) == nil
    assert {_, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(ctx.app_pid)])
    assert {output, 5} = Task.await(task, @helper_timeout)
    assert output =~ "before accepting"
    send(handler, {:continue_open, request_id})
  end

  test "packaged wait reports terminal app death after acceptance", ctx do
    target = Path.join(ctx.runtime_parent, "minga-ipc-helper-app-death.txt")
    task = Task.async(fn -> run_helper(ctx.helper, ["wait", target]) end)

    assert_receive {:opened, ^target, false, _request_id, _handler}, 2_000
    assert Task.yield(task, 100) == nil
    assert {_, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(ctx.app_pid)])
    assert {output, 1} = Task.await(task, @helper_timeout)
    assert output =~ "Minga.app exited"
  end

  test "packaged helper reports the exact terminal readiness receipt", ctx do
    target = Path.join(ctx.runtime_parent, "minga-ipc-helper-ready.txt")

    task =
      Task.async(fn -> run_helper(ctx.helper, ["open-ready", "--deadline-ms=1000", target]) end)

    assert_receive {:receipt_opened, ^target, false, receipt, server}, 2_000
    assert {:ok, applied} = Server.operation_applied(server, receipt.operation_id, 3, 7)
    assert applied.application_revision == 7

    assert :ok =
             Server.finish_native_operation(
               server,
               native_result(receipt, 3, 2, 11, true)
             )

    assert {output, 0} = Task.await(task, @helper_timeout)
    result = JSON.decode!(output)
    assert result["type"] == "completed"
    assert result["receipt"]["outcome"] == "ready"
    assert result["receipt"]["target"]["path"] == target
    assert result["receipt"]["target"]["window_id"] == 3
    assert result["receipt"]["application_revision"] == 7
    assert result["receipt"]["evidence"]["frame_seq"] == 11
  end

  test "open-ready preserves lookup identity after the endpoint disconnects", ctx do
    target = Path.join(ctx.runtime_parent, "minga-ipc-helper-receipt-disconnect.txt")

    task =
      Task.async(fn -> run_helper(ctx.helper, ["open-ready", "--deadline-ms=1000", target]) end)

    assert_receive {:receipt_opened, ^target, false, receipt, server}, 2_000
    assert {:ok, _applied} = Server.operation_applied(server, receipt.operation_id, 3, 7)
    assert :ok = stop_supervised(IPCSupervisor)

    refute File.exists?(Path.join(ctx.runtime_parent, "com.minga.editor/current.json"))

    assert {output, 3} = Task.await(task, @helper_timeout)
    result = JSON.decode!(output)
    assert result["type"] == "operation_result"
    assert result["result"] == "indeterminate"
    assert result["receipt"]["app_instance_id"] == receipt.app_instance_id
    assert result["receipt"]["core_instance_id"] == receipt.core_instance_id
    assert result["receipt"]["operation_id"] == Integer.to_string(receipt.operation_id)
  end

  test "receipt wait timeout releases its waiter without rolling back BEAM application", ctx do
    target = Path.join(ctx.runtime_parent, "minga-ipc-helper-timeout.txt")

    task =
      Task.async(fn -> run_helper(ctx.helper, ["open-ready", "--deadline-ms=100", target]) end)

    assert_receive {:receipt_opened, ^target, false, receipt, server}, 2_000
    assert {:ok, _applied} = Server.operation_applied(server, receipt.operation_id, 3, 7)

    assert {output, 1} = Task.await(task, @helper_timeout)

    assert %{"type" => "operation_result", "result" => "timeout", "receipt" => result_receipt} =
             JSON.decode!(output)

    assert result_receipt["app_instance_id"] == receipt.app_instance_id
    assert result_receipt["core_instance_id"] == receipt.core_instance_id
    assert result_receipt["operation_id"] == Integer.to_string(receipt.operation_id)

    assert {:ok, persisted} =
             Server.lookup_operation(
               server,
               receipt.app_instance_id,
               receipt.core_instance_id,
               receipt.operation_id
             )

    assert persisted.phase == :applied
    assert Server.operation_counts(server).waiters == 0
  end

  defp native_result(receipt, window_id, generation, frame_seq, focus_ready) do
    evidence = %Evidence{
      target_token: receipt.target.token,
      application_revision: receipt.application_revision,
      boundary: :metal_drawable_completed,
      generation: generation,
      frame_seq: frame_seq,
      window_id: window_id,
      focus_ready: focus_ready
    }

    %OperationNativeResult{
      operation_id: receipt.operation_id,
      target_token: receipt.target.token,
      outcome: :ready,
      evidence: evidence
    }
  end

  defp run_helper(helper, args) do
    System.cmd(helper, args, stderr_to_stdout: true)
  end
end
