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
      send(owner, {:opened, path, editor_mode?, request_id, self()})

      if String.ends_with?(path, "before-acceptance.txt") do
        receive do
          {:continue_open, ^request_id} -> :ok
        after
          5_000 -> raise "timed out waiting to release pre-acceptance IPC test"
        end
      end

      WaitRequests.register(buffer, path, request_id, waiter, wait_tracker)
    end

    sleeper =
      Port.open({:spawn_executable, ~c"/bin/sleep"}, [
        :binary,
        :exit_status,
        args: [~c"60"]
      ])

    {:os_pid, app_pid} = Port.info(sleeper, :os_pid)
    euid = File.stat!(File.cwd!()).uid

    supervisor =
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

    %{
      app_pid: app_pid,
      buffer: buffer,
      helper: helper,
      runtime_parent: runtime_parent,
      supervisor: supervisor,
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
    assert :ok = Supervisor.stop(ctx.supervisor)
    assert {output, 1} = Task.await(task, @helper_timeout)
    assert output =~ "disconnected"
  end

  test "packaged wait returns retryable status when endpoint dies before acceptance", ctx do
    target = Path.join(ctx.runtime_parent, "endpoint-before-acceptance.txt")
    task = Task.async(fn -> run_helper(ctx.helper, ["wait", target]) end)

    assert_receive {:opened, ^target, false, _request_id, _handler}, 2_000
    assert Task.yield(task, 100) == nil
    assert :ok = Supervisor.stop(ctx.supervisor)
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

  defp run_helper(helper, args) do
    System.cmd(helper, args, stderr_to_stdout: true)
  end
end
