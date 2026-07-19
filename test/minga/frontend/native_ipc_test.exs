defmodule Minga.Frontend.NativeIPCTest do
  # Not async: FIFO coverage invokes the OS mkfifo utility.
  use ExUnit.Case, async: false

  import Bitwise

  alias MingaEditor.NativeIPC.Supervisor, as: IPCSupervisor
  alias Minga.Frontend.WaitRequests

  setup do
    suffix = System.unique_integer([:positive])
    # AF_UNIX socket paths are capped near 100 bytes, so keep the test runtime parent short.
    runtime_parent = Path.join("/tmp", "minga-ipc-#{suffix}")
    runtime_dir = Path.join(runtime_parent, "com.minga.editor")
    rejected_target = runtime_parent <> "-target"
    registry = Module.concat(__MODULE__, "Events#{suffix}")
    tasks = Module.concat(__MODULE__, "Tasks#{suffix}")
    File.rm_rf!(runtime_parent)
    File.rm_rf!(rejected_target)
    File.mkdir!(runtime_parent)
    File.chmod!(runtime_parent, 0o700)
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
      send(owner, {:opened, path, editor_mode?, request_id})
      WaitRequests.register(buffer, path, request_id, waiter, wait_tracker)
    end

    open_request = fn path, editor_mode?, _editor ->
      send(owner, {:open_request, path, editor_mode?})
      :ok
    end

    euid = File.stat!(File.cwd!()).uid
    app_pid = System.pid() |> String.to_integer()

    supervisor =
      start_supervised!(
        {IPCSupervisor,
         name: nil,
         server_name: nil,
         task_supervisor_name: tasks,
         runtime_parent: runtime_parent,
         runtime_dir: runtime_dir,
         app_instance_id: "app-instance-1234567890",
         app_pid: app_pid,
         euid: euid,
         launch_nonce: "launch-nonce-123456",
         wait_tracker: tracker,
         open_wait: open_wait,
         open_request: open_request,
         kill_checker: fn ^app_pid -> true end}
      )

    on_exit(fn ->
      send(buffer, :stop)
      File.rm_rf!(runtime_parent)
      File.rm_rf!(rejected_target)
    end)

    descriptor = runtime_dir |> Path.join("current.json") |> File.read!() |> JSON.decode!()

    %{
      app_pid: app_pid,
      buffer: buffer,
      descriptor: descriptor,
      runtime_dir: runtime_dir,
      runtime_parent: runtime_parent,
      supervisor: supervisor,
      tracker: tracker
    }
  end

  test "publishes private descriptor and socket entries", ctx do
    directory = File.lstat!(ctx.runtime_dir)
    descriptor = File.lstat!(Path.join(ctx.runtime_dir, "current.json"))
    socket = File.lstat!(ctx.descriptor["socket_path"])

    assert directory.type == :directory
    assert (directory.mode &&& 0o777) == 0o700
    assert descriptor.type == :regular
    assert (descriptor.mode &&& 0o777) == 0o600
    assert socket.type == :other
    assert (socket.mode &&& 0o777) == 0o600
    assert ctx.descriptor["version"] == 1
    assert byte_size(Base.url_decode64!(ctx.descriptor["token"], padding: false)) == 32
  end

  test "refuses a symlinked runtime directory", ctx do
    suffix = System.unique_integer([:positive])
    rejected_parent = Path.join(System.tmp_dir!(), "minga-native-ipc-rejected-#{suffix}")
    symlink_runtime = Path.join(rejected_parent, "com.minga.editor")
    target = rejected_parent <> "-target"
    File.rm_rf!(rejected_parent)
    File.rm_rf!(target)
    File.mkdir!(rejected_parent)
    File.chmod!(rejected_parent, 0o700)
    File.mkdir!(target)
    File.chmod!(target, 0o700)
    File.ln_s!(target, symlink_runtime)

    on_exit(fn ->
      File.rm_rf!(rejected_parent)
      File.rm_rf!(target)
    end)

    previous_trap = Process.flag(:trap_exit, true)

    result =
      IPCSupervisor.start_link(
        name: nil,
        server_name: nil,
        task_supervisor_name: Module.concat(__MODULE__, "RejectedTasks#{suffix}"),
        runtime_parent: rejected_parent,
        runtime_dir: symlink_runtime,
        app_instance_id: "app-instance-1234567890",
        app_pid: ctx.app_pid,
        euid: File.stat!(File.cwd!()).uid,
        kill_checker: fn _pid -> true end
      )

    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end

    Process.flag(:trap_exit, previous_trap)
    assert {:error, {:shutdown, {:failed_to_start_child, _, reason}}} = result
    assert inspect(reason) =~ "insecure_runtime_entry"
  end

  test "rolls back listener socket and temp descriptor when descriptor publication fails after listen",
       ctx do
    suffix = System.unique_integer([:positive])
    parent = Path.join("/tmp", "minga-native-ipc-rollback-#{suffix}")
    runtime_dir = Path.join(parent, "com.minga.editor")
    blocker = Path.join(runtime_dir, "current.json")
    File.rm_rf!(parent)
    File.mkdir!(parent)
    File.chmod!(parent, 0o700)
    File.mkdir!(runtime_dir)
    File.chmod!(runtime_dir, 0o700)
    File.mkdir!(blocker)

    on_exit(fn -> File.rm_rf!(parent) end)

    previous_trap = Process.flag(:trap_exit, true)

    result =
      IPCSupervisor.start_link(
        name: nil,
        server_name: nil,
        task_supervisor_name: Module.concat(__MODULE__, "RollbackTasks#{suffix}"),
        runtime_parent: parent,
        runtime_dir: runtime_dir,
        app_instance_id: "app-instance-1234567890",
        app_pid: ctx.app_pid,
        euid: File.stat!(File.cwd!()).uid,
        kill_checker: fn _pid -> true end
      )

    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end

    Process.flag(:trap_exit, previous_trap)
    assert {:error, {:shutdown, {:failed_to_start_child, _, :eisdir}}} = result
    assert File.dir?(blocker)
    entries = File.ls!(runtime_dir)
    refute Enum.any?(entries, &String.starts_with?(&1, "control-"))
    refute Enum.any?(entries, &String.starts_with?(&1, "current.json.tmp-"))
    assert entries == ["current.json"]
  end

  test "authenticates a real AF_UNIX probe and rejects a substituted token", ctx do
    socket = connect(ctx.descriptor)
    send_json(socket, hello(ctx.descriptor))
    send_json(socket, %{"version" => 1, "type" => "probe"})
    assert %{"type" => "ready", "app_pid" => app_pid} = recv_json(socket)
    assert app_pid == ctx.app_pid
    :gen_tcp.close(socket)

    bad_socket = connect(ctx.descriptor)
    send_json(bad_socket, %{hello(ctx.descriptor) | "token" => String.duplicate("x", 43)})
    assert %{"type" => "error", "message" => "authentication failed"} = recv_json(bad_socket)
    assert {:error, :closed} = :gen_tcp.recv(bad_socket, 0, 1_000)
  end

  test "native opens allow files and directories while wait remains file-only", ctx do
    regular = Path.join(ctx.runtime_parent, "regular.txt")
    symlink = Path.join(ctx.runtime_parent, "regular-link.txt")
    missing = Path.join(ctx.runtime_parent, "new.txt")
    fifo = Path.join(ctx.runtime_parent, "named-pipe")
    directory = Path.join(ctx.runtime_parent, "directory")
    File.write!(regular, "ok\n")
    File.ln_s!(regular, symlink)
    File.mkdir!(directory)
    assert {"", 0} = System.cmd("mkfifo", [fifo])

    socket = connect(ctx.descriptor)
    send_json(socket, hello(ctx.descriptor))

    send_json(socket, %{
      "version" => 1,
      "type" => "open",
      "paths" => [missing, regular, symlink, directory],
      "editor" => true
    })

    assert %{"type" => "completed", "exit_code" => 0} = recv_json(socket)
    assert_receive {:open_request, ^missing, true}
    assert_receive {:open_request, ^regular, true}
    assert_receive {:open_request, ^symlink, true}
    assert_receive {:open_request, ^directory, true}
    :gen_tcp.close(socket)

    for target <- [fifo, "/dev/null"] do
      socket = connect(ctx.descriptor)
      send_json(socket, hello(ctx.descriptor))
      send_json(socket, %{"version" => 1, "type" => "open", "paths" => [target]})

      assert %{
               "type" => "completed",
               "exit_code" => 1,
               "message" => message
             } = recv_json(socket)

      assert message =~ "unsupported_native_ipc_target"
      refute_receive {:open_request, ^target, _editor_mode?}
      :gen_tcp.close(socket)
    end

    for target <- [directory, fifo] do
      wait_socket = connect(ctx.descriptor)
      send_json(wait_socket, hello(ctx.descriptor))
      send_json(wait_socket, %{"version" => 1, "type" => "open_wait", "path" => target})

      assert %{
               "type" => "completed",
               "request_id" => request_id,
               "exit_code" => 1,
               "message" => wait_message
             } = recv_json(wait_socket)

      assert wait_message =~ "unsupported_native_ipc_target"
      refute_receive {:opened, ^target, _editor_mode?, _request_id}

      send_json(wait_socket, %{
        "version" => 1,
        "type" => "completion_ack",
        "request_id" => request_id
      })

      :gen_tcp.close(wait_socket)
    end
  end

  test "wait acceptance is synchronous and target-aware", ctx do
    target = Path.expand("native-ipc-target.txt")
    socket = connect(ctx.descriptor)
    send_json(socket, hello(ctx.descriptor))
    send_json(socket, %{"version" => 1, "type" => "open_wait", "path" => target})

    assert_receive {:opened, ^target, false, request_id}, 1_000

    assert %{
             "type" => "accepted",
             "request_id" => ^request_id,
             "app_pid" => app_pid
           } = recv_json(socket)

    assert app_pid == ctx.app_pid
    assert :ok = WaitRequests.accept(ctx.buffer, Path.expand("different.txt"), ctx.tracker)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 50)
    assert :ok = WaitRequests.accept(ctx.buffer, target, ctx.tracker)

    assert %{"type" => "completed", "request_id" => ^request_id, "exit_code" => 0} =
             recv_json(socket)

    send_json(socket, %{"version" => 1, "type" => "completion_ack", "request_id" => request_id})
    assert :ok = WaitRequests.await_acknowledgements(1_000, ctx.tracker)
  end

  test "an accepted request terminates when the wait tracker exits", ctx do
    target = Path.expand("tracker-exit-target.txt")
    socket = connect(ctx.descriptor)
    send_json(socket, hello(ctx.descriptor))
    send_json(socket, %{"version" => 1, "type" => "open_wait", "path" => target})
    assert %{"type" => "accepted", "request_id" => request_id} = recv_json(socket)

    GenServer.stop(ctx.tracker, :shutdown)

    assert %{
             "type" => "completed",
             "request_id" => ^request_id,
             "exit_code" => 1,
             "message" => "wait tracker exited before completion"
           } = recv_json(socket)

    send_json(socket, %{"version" => 1, "type" => "completion_ack", "request_id" => request_id})
  end

  test "endpoint restart disconnects an accepted request", ctx do
    target = Path.expand("restart-target.txt")
    socket = connect(ctx.descriptor)
    send_json(socket, hello(ctx.descriptor))
    send_json(socket, %{"version" => 1, "type" => "open_wait", "path" => target})
    assert %{"type" => "accepted"} = recv_json(socket)

    assert :ok = Supervisor.stop(ctx.supervisor)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  defp connect(descriptor) do
    {:ok, socket} =
      :gen_tcp.connect({:local, descriptor["socket_path"]}, 0, [
        :binary,
        {:active, false},
        {:packet, 4}
      ])

    socket
  end

  defp hello(descriptor) do
    %{
      "version" => 1,
      "type" => "hello",
      "app_instance_id" => descriptor["app_instance_id"],
      "core_instance_id" => descriptor["core_instance_id"],
      "token" => descriptor["token"],
      "expected_launch_nonce" => descriptor["launch_nonce"]
    }
  end

  defp send_json(socket, value), do: :ok = :gen_tcp.send(socket, JSON.encode!(value))

  defp recv_json(socket) do
    {:ok, payload} = :gen_tcp.recv(socket, 0, 1_000)
    JSON.decode!(payload)
  end
end
