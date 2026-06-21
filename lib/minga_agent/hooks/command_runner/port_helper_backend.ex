defmodule MingaAgent.Hooks.CommandRunner.PortHelperBackend do
  @moduledoc """
  Port-backed hook helper backend for `MingaAgent.Hooks.CommandRunner`.

  This module owns the OS process boundary: starting `minga-hook-runner`, sending the JSON payload, receiving Port messages, and terminating the helper when the guard timeout fires.
  """

  @behaviour MingaAgent.Hooks.CommandRunner.HelperBackend

  @enforce_keys [:port]
  defstruct [:port, :os_pid]

  @typedoc "Port-backed helper handle."
  @type t :: %__MODULE__{port: port(), os_pid: pos_integer() | nil}

  @impl true
  @spec start(String.t(), [String.t()], String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(helper_path, args, payload_json, _opts)
      when is_binary(helper_path) and is_list(args) and is_binary(payload_json) do
    port =
      Port.open({:spawn_executable, helper_path}, [
        :binary,
        :exit_status,
        args: args
      ])

    handle = %__MODULE__{port: port, os_pid: port_os_pid(port)}
    send_payload(port, payload_json)
    {:ok, handle}
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @impl true
  @spec next_event(t(), non_neg_integer()) :: MingaAgent.Hooks.CommandRunner.HelperBackend.event()
  def next_event(%__MODULE__{port: port} = handle, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        {:data, data, handle}

      {^port, {:exit_status, status}} when is_integer(status) and status >= 0 ->
        {:exit_status, status, handle}
    after
      timeout_ms -> :timeout
    end
  end

  @impl true
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{port: port, os_pid: os_pid}) do
    kill_helper_process(os_pid)
    close_port(port)
  end

  @spec send_payload(port(), String.t()) :: :ok
  defp send_payload(port, payload_json) do
    Port.command(port, payload_json)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  @spec port_os_pid(port()) :: pos_integer() | nil
  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _other -> nil
    end
  end

  @spec kill_helper_process(pos_integer() | nil) :: :ok
  defp kill_helper_process(nil), do: :ok

  defp kill_helper_process(pid) do
    pid_arg = Integer.to_string(pid)
    System.cmd("kill", ["-TERM", pid_arg], stderr_to_stdout: true)
    System.cmd("kill", ["-KILL", pid_arg], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end
end
