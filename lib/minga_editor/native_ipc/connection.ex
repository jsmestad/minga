defmodule MingaEditor.NativeIPC.Connection do
  @moduledoc false

  alias Minga.Frontend.WaitRequestCompletion
  alias MingaEditor.NativeIPC.Identity

  @version 1
  @handshake_timeout 5_000
  @completion_ack_timeout 2_000

  @spec serve(port(), Identity.t(), keyword()) :: :ok
  def serve(socket, identity, opts) do
    result =
      with {:ok, hello} <- receive_json(socket, @handshake_timeout),
           :ok <- authenticate(hello, identity, opts),
           {:ok, command} <- receive_json(socket, @handshake_timeout) do
        dispatch(socket, command, identity, opts)
      else
        {:error, reason} -> send_error(socket, reason)
      end

    _ = :gen_tcp.close(socket)
    result
  end

  @spec receive_json(port(), timeout()) :: {:ok, map()} | {:error, term()}
  defp receive_json(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, payload} -> decode_object(payload)
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @spec decode_object(binary()) :: {:ok, map()} | {:error, term()}
  defp decode_object(payload) do
    case JSON.decode(payload) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_json_object}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  @spec authenticate(map(), Identity.t(), keyword()) ::
          :ok | {:error, term()}
  defp authenticate(
         %{
           "version" => @version,
           "type" => "hello",
           "app_instance_id" => app_instance_id,
           "core_instance_id" => core_instance_id,
           "token" => token,
           "expected_launch_nonce" => expected_nonce
         },
         identity,
         opts
       ) do
    with true <- secure_equal?(app_instance_id, identity.app_instance_id),
         true <- secure_equal?(core_instance_id, identity.core_instance_id),
         true <- secure_equal?(token, identity.token),
         :ok <- validate_launch_nonce(expected_nonce, identity.launch_nonce),
         true <- app_alive?(identity.app_pid, opts) do
      :ok
    else
      false -> {:error, :authentication_failed}
      {:error, _reason} = error -> error
    end
  end

  defp authenticate(_hello, _identity, _opts), do: {:error, :authentication_failed}

  @spec validate_launch_nonce(term(), String.t() | nil) :: :ok | {:error, atom()}
  defp validate_launch_nonce(nil, _actual), do: :ok

  defp validate_launch_nonce(expected, actual) when is_binary(expected) and is_binary(actual) do
    if secure_equal?(expected, actual), do: :ok, else: {:error, :launch_nonce_mismatch}
  end

  defp validate_launch_nonce(_expected, _actual), do: {:error, :launch_nonce_mismatch}

  @spec dispatch(port(), map(), Identity.t(), keyword()) :: :ok
  defp dispatch(socket, %{"version" => @version, "type" => "probe"}, identity, _opts) do
    send_json(socket, %{
      version: @version,
      type: "ready",
      app_instance_id: identity.app_instance_id,
      core_instance_id: identity.core_instance_id,
      app_pid: identity.app_pid
    })
  end

  defp dispatch(
         socket,
         %{"version" => @version, "type" => "open_wait", "path" => path} = command,
         identity,
         opts
       )
       when is_binary(path) do
    request_id = random_request_id()
    editor_mode? = Map.get(command, "editor", false) == true

    with {:ok, tracker, monitor} <- monitor_wait_tracker(opts),
         :ok <- open_and_register(path, editor_mode?, request_id, tracker, opts) do
      :ok =
        send_json(socket, %{
          version: @version,
          type: "accepted",
          request_id: request_id,
          app_instance_id: identity.app_instance_id,
          core_instance_id: identity.core_instance_id,
          app_pid: identity.app_pid
        })

      await_completion(socket, request_id, tracker, monitor)
    else
      {:error, reason} ->
        send_untracked_completion(
          socket,
          request_id,
          1,
          "file open failed: #{inspect(reason)}"
        )
    end
  end

  defp dispatch(
         socket,
         %{"version" => @version, "type" => "open", "paths" => paths} = command,
         _identity,
         opts
       )
       when is_list(paths) do
    editor_mode? = Map.get(command, "editor", false) == true

    case open_paths(paths, editor_mode?, opts) do
      :ok ->
        send_json(socket, %{version: @version, type: "completed", exit_code: 0})

      {:error, reason} ->
        send_json(socket, completed("open", 1, "file open failed: #{inspect(reason)}"))
    end
  end

  defp dispatch(socket, _command, _identity, _opts), do: send_error(socket, :unsupported_command)

  @spec monitor_wait_tracker(keyword()) :: {:ok, pid(), reference()} | {:error, atom()}
  defp monitor_wait_tracker(opts) do
    tracker = Keyword.get(opts, :wait_tracker, Minga.Frontend.WaitRequests)

    case GenServer.whereis(tracker) do
      pid when is_pid(pid) -> {:ok, pid, Process.monitor(pid)}
      nil -> {:error, :wait_tracker_unavailable}
    end
  end

  @spec open_and_register(String.t(), boolean(), String.t(), pid(), keyword()) ::
          :ok | {:error, term()}
  defp open_and_register(path, editor_mode?, request_id, tracker, opts) do
    with {:ok, expanded} <- absolute_path(path),
         :ok <- validate_wait_target(expanded) do
      editor = Keyword.get(opts, :editor_server, MingaEditor)
      open_wait = Keyword.get(opts, :open_wait, &MingaEditor.open_wait/6)
      open_wait.(expanded, editor_mode?, request_id, self(), editor, tracker)
    end
  catch
    :exit, reason -> {:error, {:editor_unavailable, reason}}
  end

  @spec open_paths([term()], boolean(), keyword()) :: :ok | {:error, term()}
  defp open_paths(paths, editor_mode?, opts) do
    editor = Keyword.get(opts, :editor_server, MingaEditor)
    open_request = Keyword.get(opts, :open_request, &MingaEditor.open_native/3)

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      with true <- is_binary(path),
           {:ok, expanded} <- absolute_path(path),
           :ok <- validate_open_target(expanded),
           :ok <- open_request.(expanded, editor_mode?, editor) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :invalid_path}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  catch
    :exit, reason -> {:error, {:editor_unavailable, reason}}
  end

  @spec absolute_path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  defp absolute_path(path) do
    if Path.type(path) == :absolute,
      do: {:ok, Path.expand(path)},
      else: {:error, :path_must_be_absolute}
  end

  @spec validate_open_target(String.t()) :: :ok | {:error, term()}
  defp validate_open_target(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: type}} when type in [:regular, :directory] ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsupported_native_ipc_target, type}}

      {:error, :enoent} ->
        validate_missing_target(path)

      {:error, reason} ->
        {:error, {:native_ipc_target, reason}}
    end
  end

  @spec validate_wait_target(String.t()) :: :ok | {:error, term()}
  defp validate_wait_target(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsupported_native_ipc_target, type}}
      {:error, :enoent} -> validate_missing_target(path)
      {:error, reason} -> {:error, {:native_ipc_target, reason}}
    end
  end

  @spec validate_missing_target(String.t()) :: :ok | {:error, term()}
  defp validate_missing_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsupported_native_ipc_target, type}}
      {:error, reason} -> {:error, {:native_ipc_target, reason}}
    end
  end

  @spec await_completion(port(), String.t(), pid(), reference()) :: :ok
  defp await_completion(socket, request_id, tracker, tracker_monitor) do
    :ok = :inet.setopts(socket, active: :once)

    receive do
      %WaitRequestCompletion{request_id: ^request_id, outcome: :accepted} ->
        send_completion_and_await_ack(socket, request_id, tracker, tracker_monitor, 0, nil)

      %WaitRequestCompletion{request_id: ^request_id, outcome: {:cancelled, message}} ->
        send_completion_and_await_ack(socket, request_id, tracker, tracker_monitor, 1, message)

      {:DOWN, ^tracker_monitor, :process, ^tracker, _reason} ->
        send_untracked_completion(
          socket,
          request_id,
          1,
          "wait tracker exited before completion"
        )

      {:tcp_closed, ^socket} ->
        Process.demonitor(tracker_monitor, [:flush])
        :ok

      {:tcp_error, ^socket, _reason} ->
        Process.demonitor(tracker_monitor, [:flush])
        :ok
    end
  end

  @spec send_untracked_completion(port(), String.t(), 0 | 1, String.t() | nil) :: :ok
  defp send_untracked_completion(socket, request_id, code, message) do
    :ok = send_json(socket, completed(request_id, code, message))
    _acknowledged? = await_client_ack(socket, request_id)
    :ok
  end

  @spec send_completion_and_await_ack(
          port(),
          String.t(),
          pid(),
          reference(),
          0 | 1,
          String.t() | nil
        ) :: :ok
  defp send_completion_and_await_ack(socket, request_id, tracker, tracker_monitor, code, message) do
    :ok = send_json(socket, completed(request_id, code, message))

    if await_client_ack(socket, request_id) do
      Minga.Frontend.WaitRequests.acknowledge(request_id, tracker)
    end

    Process.demonitor(tracker_monitor, [:flush])
    :ok
  end

  @spec await_client_ack(port(), String.t()) :: boolean()
  defp await_client_ack(socket, request_id) do
    :ok = :inet.setopts(socket, active: false)

    match?(
      {:ok, %{"version" => @version, "type" => "completion_ack", "request_id" => ^request_id}},
      receive_json(socket, @completion_ack_timeout)
    )
  end

  @spec completed(String.t(), 0 | 1, String.t() | nil) :: map()
  defp completed(request_id, exit_code, nil) do
    %{version: @version, type: "completed", request_id: request_id, exit_code: exit_code}
  end

  defp completed(request_id, exit_code, message) do
    %{
      version: @version,
      type: "completed",
      request_id: request_id,
      exit_code: exit_code,
      message: message
    }
  end

  @spec send_error(port(), term()) :: :ok
  defp send_error(socket, reason) do
    send_json(socket, %{
      version: @version,
      type: "error",
      message: error_message(reason)
    })
  end

  @spec error_message(term()) :: String.t()
  defp error_message(:authentication_failed), do: "authentication failed"
  defp error_message(:launch_nonce_mismatch), do: "launch nonce mismatch"
  defp error_message(:unsupported_command), do: "unsupported command"
  defp error_message(reason), do: "IPC request failed: #{inspect(reason)}"

  @spec send_json(port(), map()) :: :ok
  defp send_json(socket, value) do
    case :gen_tcp.send(socket, JSON.encode!(value)) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec secure_equal?(term(), String.t()) :: boolean()
  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  @spec app_alive?(pos_integer(), keyword()) :: boolean()
  defp app_alive?(pid, opts) do
    checker = Keyword.get(opts, :kill_checker, &default_kill_checker/1)
    checker.(pid)
  end

  @spec default_kill_checker(pos_integer()) :: boolean()
  defp default_kill_checker(pid), do: Minga.Session.Swap.pid_alive?(pid)

  @spec random_request_id() :: String.t()
  defp random_request_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
