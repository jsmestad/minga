defmodule Minga.Parser.BufferLifecycle do
  @moduledoc """
  Editor-buffer registration, unregistration, activity, eviction, and monitors.

  Functions accept aggregate values and return typed transitions for the manager
  to install. Ordering-sensitive monitor and parser-tree effects stay here.
  """

  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.ParseScheduler
  alias Minga.Parser.ParseSync
  alias Minga.Parser.PortLifecycle
  alias Minga.Parser.RequestHandler
  alias Minga.Parser.RequestState

  @type aggregates :: {BufferRegistry.t(), ParseScheduler.t(), RequestState.t()}
  @type lifecycle_result :: ParseSync.result()

  @doc "Registers or refreshes an editor buffer and its process monitor."
  @spec register(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid(),
          BufferConfig.t()
        ) :: {pos_integer(), aggregates()}
  def register(port, buffers, scheduler, requests, buffer_pid, %BufferConfig{} = config) do
    {buffer_id, status, buffers} =
      BufferRegistry.register(buffers, buffer_pid, config, monotonic_ms())

    buffers = update_monitor(port, buffers, buffer_pid, status)
    scheduler = release_replaced(scheduler, buffer_pid, status)
    requests = fail_replaced_requests(requests, buffer_pid, status)
    {buffer_id, {buffers, scheduler, requests}}
  end

  @doc "Unregisters a buffer, closes its parser tree, and continues queued parsing."
  @spec unregister(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid(),
          boolean()
        ) :: lifecycle_result()
  def unregister(port, buffers, scheduler, requests, buffer_pid, demonitor? \\ true) do
    requests = RequestHandler.fail_buffer(requests, buffer_pid)
    {buffer_id, monitor_ref, buffers} = BufferRegistry.unregister(buffers, buffer_pid)
    maybe_demonitor(monitor_ref, demonitor?)
    PortLifecycle.close_buffer(port, buffer_id)
    scheduler = ParseScheduler.release(scheduler, buffer_pid)
    ParseSync.dispatch_next(port, buffers, scheduler, requests)
  end

  @doc "Unregisters a buffer only when DOWN is its registration monitor."
  @spec handle_down(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid(),
          reference()
        ) :: :ignored | lifecycle_result()
  def handle_down(port, buffers, scheduler, requests, buffer_pid, monitor_ref) do
    if BufferRegistry.monitored?(buffers, buffer_pid, monitor_ref) do
      unregister(port, buffers, scheduler, requests, buffer_pid, false)
    else
      :ignored
    end
  end

  @doc "Refreshes the activity timestamp for a registered buffer."
  @spec touch(BufferRegistry.t(), pid()) :: BufferRegistry.t()
  def touch(buffers, buffer_pid), do: BufferRegistry.touch(buffers, buffer_pid, monotonic_ms())

  @doc "Evicts inactive registrations and fails every request owned by each evicted PID."
  @spec evict_inactive(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          [pid()],
          non_neg_integer()
        ) :: {[pid()], lifecycle_result()}
  def evict_inactive(port, buffers, scheduler, requests, protected_pids, ttl_ms) do
    {evicted, buffers} =
      BufferRegistry.evict_inactive(buffers, protected_pids, ttl_ms, monotonic_ms())

    Enum.each(evicted, fn {_buffer_pid, buffer_id, monitor_ref} ->
      maybe_demonitor(monitor_ref, true)
      PortLifecycle.close_buffer(port, buffer_id)
    end)

    evicted_pids = Enum.map(evicted, &elem(&1, 0))

    {scheduler, requests} =
      Enum.reduce(evicted_pids, {scheduler, requests}, fn buffer_pid, {scheduler, requests} ->
        {
          ParseScheduler.release(scheduler, buffer_pid),
          RequestHandler.fail_buffer(requests, buffer_pid)
        }
      end)

    {evicted_pids, ParseSync.dispatch_next(port, buffers, scheduler, requests)}
  end

  @spec update_monitor(
          port() | nil,
          BufferRegistry.t(),
          pid(),
          BufferRegistry.register_status()
        ) :: BufferRegistry.t()
  defp update_monitor(_port, buffers, buffer_pid, :new),
    do: BufferRegistry.put_monitor(buffers, buffer_pid, Process.monitor(buffer_pid))

  defp update_monitor(_port, buffers, _buffer_pid, :existing), do: buffers

  defp update_monitor(port, buffers, _buffer_pid, {:replaced, old_id}) do
    PortLifecycle.close_buffer(port, old_id)
    buffers
  end

  @spec release_replaced(ParseScheduler.t(), pid(), BufferRegistry.register_status()) ::
          ParseScheduler.t()
  defp release_replaced(scheduler, buffer_pid, {:replaced, _old_id}),
    do: ParseScheduler.release(scheduler, buffer_pid)

  defp release_replaced(scheduler, _buffer_pid, _status), do: scheduler

  @spec fail_replaced_requests(RequestState.t(), pid(), BufferRegistry.register_status()) ::
          RequestState.t()
  defp fail_replaced_requests(requests, buffer_pid, {:replaced, _old_id}),
    do: RequestHandler.fail_buffer(requests, buffer_pid)

  defp fail_replaced_requests(requests, _buffer_pid, _status), do: requests

  @spec maybe_demonitor(reference() | nil, boolean()) :: :ok
  defp maybe_demonitor(nil, _demonitor?), do: :ok
  defp maybe_demonitor(_monitor_ref, false), do: :ok

  defp maybe_demonitor(monitor_ref, true) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  @spec monotonic_ms() :: integer()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
