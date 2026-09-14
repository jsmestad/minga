defmodule MingaEditor.NativeIPC.Connection do
  @moduledoc false

  alias Minga.Frontend.WaitRequestCompletion
  alias MingaEditor.NativeIPC.Identity
  alias MingaEditor.NativeIPC.OperationReceipt
  alias MingaEditor.NativeIPC.OperationReceipt.Target
  alias MingaEditor.NativeIPC.Server

  @version 1
  @handshake_timeout 5_000
  @completion_ack_timeout 2_000
  @maximum_operation_deadline_ms 30_000

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

  defp dispatch(
         socket,
         %{"version" => @version, "type" => "open_ready", "path" => path} = command,
         identity,
         opts
       )
       when is_binary(path) do
    editor_mode? = Map.get(command, "editor", false) == true
    deadline_ms = operation_deadline(command)
    deadline_at_ms = System.monotonic_time(:millisecond) + deadline_ms

    with {:ok, expanded} <- absolute_path(path),
         :ok <- validate_wait_target(expanded),
         {:ok, receipt_server} <- receipt_server(opts),
         {:ok, receipt} <-
           Server.admit_operation(receipt_server, expanded, Target.token_for_path(expanded)) do
      :ok = send_receipt(socket, "accepted", receipt)
      apply_receipt_open(expanded, editor_mode?, receipt, receipt_server, opts)
      send_current_receipt(socket, receipt_server, receipt.operation_id)

      await_operation_terminal(
        socket,
        identity,
        receipt.operation_id,
        remaining_deadline_ms(deadline_at_ms),
        receipt_server
      )
    else
      {:error, reason} -> send_error(socket, reason)
    end
  end

  defp dispatch(
         socket,
         %{
           "version" => @version,
           "type" => "operation_lookup",
           "app_instance_id" => app_id,
           "core_instance_id" => core_id,
           "operation_id" => operation_id
         },
         _identity,
         opts
       ) do
    with {:ok, receipt_server} <- receipt_server(opts),
         {:ok, parsed_id} <- parse_operation_id(operation_id),
         {:ok, receipt} <- Server.lookup_operation(receipt_server, app_id, core_id, parsed_id) do
      send_receipt(socket, "receipt", receipt)
    else
      {:error, reason} -> send_operation_observation(socket, "lookup", reason)
    end
  end

  defp dispatch(
         socket,
         %{
           "version" => @version,
           "type" => "operation_wait",
           "app_instance_id" => app_id,
           "core_instance_id" => core_id,
           "operation_id" => operation_id
         } = command,
         _identity,
         opts
       ) do
    with {:ok, receipt_server} <- receipt_server(opts),
         {:ok, parsed_id} <- parse_operation_id(operation_id) do
      await_operation(
        socket,
        app_id,
        core_id,
        parsed_id,
        operation_deadline(command),
        receipt_server
      )
    else
      {:error, reason} -> send_operation_observation(socket, "wait", reason)
    end
  end

  defp dispatch(socket, _command, _identity, _opts), do: send_error(socket, :unsupported_command)

  @spec send_current_receipt(port(), GenServer.server(), pos_integer()) :: :ok
  defp send_current_receipt(socket, receipt_server, operation_id) do
    identity = Server.identity(receipt_server)

    case Server.lookup_operation(
           receipt_server,
           identity.app_instance_id,
           identity.core_instance_id,
           operation_id
         ) do
      {:ok, current} -> send_receipt(socket, "progress", current)
      {:error, _reason} -> :ok
    end
  end

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

  @spec apply_receipt_open(
          String.t(),
          boolean(),
          OperationReceipt.t(),
          GenServer.server(),
          keyword()
        ) :: :ok
  defp apply_receipt_open(path, editor_mode?, receipt, receipt_server, opts) do
    editor = Keyword.get(opts, :editor_server, MingaEditor)
    open_receipt = Keyword.get(opts, :open_receipt, &MingaEditor.open_native_receipt/5)

    case open_receipt.(path, editor_mode?, receipt, receipt_server, editor) do
      :ok ->
        :ok

      {:error, reason} ->
        Server.finish_operation(
          receipt_server,
          receipt.operation_id,
          :rejected,
          nil,
          nil,
          inspect(reason)
        )
    end
  catch
    :exit, reason ->
      Server.finish_operation(
        receipt_server,
        receipt.operation_id,
        :indeterminate,
        nil,
        nil,
        Exception.format_exit(reason)
      )
  end

  @spec await_operation_terminal(
          port(),
          Identity.t(),
          pos_integer(),
          pos_integer(),
          GenServer.server()
        ) :: :ok
  defp await_operation_terminal(socket, identity, operation_id, deadline_ms, receipt_server) do
    await_operation(
      socket,
      identity.app_instance_id,
      identity.core_instance_id,
      operation_id,
      deadline_ms,
      receipt_server
    )
  end

  @spec await_operation(
          port(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          GenServer.server()
        ) :: :ok
  defp await_operation(socket, app_id, core_id, operation_id, deadline_ms, receipt_server) do
    ref = make_ref()

    case Server.await_operation(receipt_server, app_id, core_id, operation_id, self(), ref) do
      {:ready, receipt} -> send_receipt(socket, "completed", receipt)
      :waiting -> receive_operation_wait(socket, receipt_server, ref, operation_id, deadline_ms)
      {:error, reason} -> send_operation_observation(socket, "wait", reason)
    end
  end

  @spec receive_operation_wait(
          port(),
          GenServer.server(),
          reference(),
          pos_integer(),
          pos_integer()
        ) :: :ok
  defp receive_operation_wait(socket, receipt_server, ref, operation_id, deadline_ms) do
    :ok = :inet.setopts(socket, active: :once)

    receive do
      {:operation_receipt, ^ref, receipt} ->
        send_receipt(socket, "completed", receipt)

      {:tcp, ^socket, payload} ->
        cancel_operation_wait(receipt_server, ref)
        receive_wait_control(socket, payload, operation_id)

      {:tcp_closed, ^socket} ->
        cancel_operation_wait(receipt_server, ref)

      {:tcp_error, ^socket, _reason} ->
        cancel_operation_wait(receipt_server, ref)
    after
      deadline_ms ->
        cancel_operation_wait(receipt_server, ref)
        send_operation_observation(socket, "wait", :timeout)
    end
  end

  @spec receive_wait_control(port(), binary(), pos_integer()) :: :ok
  defp receive_wait_control(socket, payload, operation_id) do
    case decode_object(payload) do
      {:ok, %{"version" => @version, "type" => "cancel_wait", "operation_id" => id}} ->
        case parse_operation_id(id) do
          {:ok, ^operation_id} -> send_operation_observation(socket, "wait", :cancelled)
          _other -> send_error(socket, :invalid_cancel_identity)
        end

      _other ->
        send_error(socket, :invalid_wait_control)
    end
  end

  @spec cancel_operation_wait(GenServer.server(), reference()) :: :ok
  defp cancel_operation_wait(receipt_server, ref) do
    Server.cancel_operation_wait(receipt_server, ref)
  catch
    :exit, _reason -> :ok
  end

  @spec receipt_server(keyword()) ::
          {:ok, GenServer.server()} | {:error, :receipt_store_unavailable}
  defp receipt_server(opts) do
    case Keyword.get(opts, :receipt_server) do
      nil -> {:error, :receipt_store_unavailable}
      server -> {:ok, server}
    end
  end

  @spec operation_deadline(map()) :: pos_integer()
  defp operation_deadline(command) do
    case Map.get(command, "deadline_ms", 15_000) do
      value when is_integer(value) and value > 0 -> min(value, @maximum_operation_deadline_ms)
      _other -> 15_000
    end
  end

  @spec remaining_deadline_ms(integer()) :: pos_integer()
  defp remaining_deadline_ms(deadline_at_ms) do
    max(deadline_at_ms - System.monotonic_time(:millisecond), 1)
  end

  @spec parse_operation_id(term()) :: {:ok, pos_integer()} | {:error, :invalid_operation_id}
  defp parse_operation_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_operation_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> {:error, :invalid_operation_id}
    end
  end

  defp parse_operation_id(_value), do: {:error, :invalid_operation_id}

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

  @spec send_receipt(port(), String.t(), OperationReceipt.t()) :: :ok
  defp send_receipt(socket, type, receipt) do
    send_json(socket, %{
      version: @version,
      type: type,
      receipt: OperationReceipt.to_map(receipt)
    })
  end

  @spec send_operation_observation(port(), String.t(), atom()) :: :ok
  defp send_operation_observation(socket, observation, reason) do
    send_json(socket, %{
      version: @version,
      type: "operation_result",
      observation: observation,
      result: Atom.to_string(reason)
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
