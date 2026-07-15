defmodule Minga.Extension.Instance.Worker do
  @moduledoc "Linked, monitored, bounded transition work owned by one Instance."

  @typedoc "Identity and cancellation handles for one asynchronous transition."
  @enforce_keys [:id, :kind, :pid, :monitor, :timer]
  defstruct [:id, :kind, :pid, :monitor, :timer]

  @type kind :: :start | :terminate | {:finalizer, atom()} | :cleanup
  @type failure ::
          {:transition_worker_failed, kind(),
           {:raise, Exception.t(), Exception.stacktrace()}
           | {:throw | :exit, term(), Exception.stacktrace()}}
  @type t :: %__MODULE__{
          id: reference(),
          kind: kind(),
          pid: pid(),
          monitor: reference(),
          timer: reference()
        }

  @doc "Starts linked transition work and arms its deterministic timeout."
  @spec start(pid(), kind(), pos_integer(), (-> term())) :: t()
  def start(owner, kind, timeout_ms, fun)
      when is_pid(owner) and is_integer(timeout_ms) and timeout_ms > 0 and is_function(fun, 0) do
    start(owner, kind, timeout_ms, make_ref(), fun)
  end

  @doc "Starts transition work with a caller-owned identity for progress messages."
  @spec start(pid(), kind(), pos_integer(), reference(), (-> term())) :: t()
  def start(owner, kind, timeout_ms, id, fun)
      when is_pid(owner) and is_integer(timeout_ms) and timeout_ms > 0 and is_reference(id) and
             is_function(fun, 0) do
    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(owner, {__MODULE__, :done, id, normalize(kind, fun)}) end,
        [:link, :monitor]
      )

    timer = Process.send_after(owner, {__MODULE__, :timeout, id, kind}, timeout_ms)
    %__MODULE__{id: id, kind: kind, pid: pid, monitor: monitor, timer: timer}
  end

  @doc "Cancels timeout/monitor bookkeeping after a matching completion."
  @spec complete(t()) :: :ok
  def complete(%__MODULE__{} = worker) do
    _ = Process.cancel_timer(worker.timer)
    Process.demonitor(worker.monitor, [:flush])
    :ok
  end

  @doc "Kills work which exceeded its authority-owned deadline."
  @spec timeout(t()) :: :ok
  def timeout(%__MODULE__{} = worker) do
    Process.unlink(worker.pid)
    Process.exit(worker.pid, :kill)
    Process.demonitor(worker.monitor, [:flush])
    :ok
  end

  @doc "Cancels work whose transition lost lifecycle authority."
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{} = worker) do
    _ = Process.cancel_timer(worker.timer)
    Process.unlink(worker.pid)
    Process.exit(worker.pid, :kill)
    Process.demonitor(worker.monitor, [:flush])
    :ok
  end

  @doc "Clears timer bookkeeping after a worker DOWN."
  @spec down(t()) :: :ok
  def down(%__MODULE__{} = worker) do
    _ = Process.cancel_timer(worker.timer)
    :ok
  end

  @spec normalize(kind(), (-> term())) :: {:ok, term()} | {:error, failure()}
  defp normalize(kind, fun) do
    {:ok, fun.()}
  rescue
    error ->
      {:error, {:transition_worker_failed, kind, {:raise, error, __STACKTRACE__}}}
  catch
    thrown_kind, reason ->
      {:error, {:transition_worker_failed, kind, {thrown_kind, reason, __STACKTRACE__}}}
  end
end
