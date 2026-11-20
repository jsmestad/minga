defmodule Minga.Parser.BufferLifecycle do
  @moduledoc """
  Editor-buffer registration, unregistration, activity, eviction, and monitors.

  Workflows return the updated synchronization value for the manager to install.
  Ordering-sensitive monitor and parser-tree effects stay here.
  """

  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.ParseSync
  alias Minga.Parser.PortLifecycle
  alias Minga.Parser.RequestHandler

  @doc "Registers or refreshes an editor buffer and its process monitor."
  @spec register(ParseSync.t(), port() | nil, pid(), BufferConfig.t()) ::
          {pos_integer(), ParseSync.t()}
  def register(work, port, buffer_pid, %BufferConfig{} = config) do
    {buffer_id, status, buffers} =
      BufferRegistry.register(work.buffers, buffer_pid, config, monotonic_ms())

    work = finish_registration(ParseSync.put_buffers(work, buffers), port, buffer_pid, status)
    {buffer_id, work}
  end

  @doc "Unregisters a buffer, closes its parser tree, and continues queued parsing."
  @spec unregister(ParseSync.t(), port() | nil, pid(), boolean()) :: ParseSync.t()
  def unregister(work, port, buffer_pid, demonitor? \\ true) do
    work = fail_requests(work, buffer_pid)
    {buffer_id, monitor_ref, buffers} = BufferRegistry.unregister(work.buffers, buffer_pid)
    maybe_demonitor(monitor_ref, demonitor?)
    PortLifecycle.close_buffer(port, buffer_id)

    work
    |> ParseSync.put_buffers(buffers)
    |> ParseSync.release_buffer(buffer_pid)
    |> ParseSync.dispatch_next(port)
  end

  @doc "Unregisters a buffer only when DOWN is its registration monitor."
  @spec handle_down(ParseSync.t(), port() | nil, pid(), reference()) :: :ignored | ParseSync.t()
  def handle_down(work, port, buffer_pid, monitor_ref) do
    if BufferRegistry.monitored?(work.buffers, buffer_pid, monitor_ref) do
      unregister(work, port, buffer_pid, false)
    else
      :ignored
    end
  end

  @doc "Refreshes the activity timestamp for a registered buffer."
  @spec touch(BufferRegistry.t(), pid()) :: BufferRegistry.t()
  def touch(buffers, buffer_pid), do: BufferRegistry.touch(buffers, buffer_pid, monotonic_ms())

  @doc "Evicts inactive registrations and fails every request owned by each evicted PID."
  @spec evict_inactive(ParseSync.t(), port() | nil, [pid()], non_neg_integer()) ::
          {[pid()], ParseSync.t()}
  def evict_inactive(work, port, protected_pids, ttl_ms) do
    {evicted, buffers} =
      BufferRegistry.evict_inactive(work.buffers, protected_pids, ttl_ms, monotonic_ms())

    Enum.each(evicted, fn {_buffer_pid, buffer_id, monitor_ref} ->
      maybe_demonitor(monitor_ref, true)
      PortLifecycle.close_buffer(port, buffer_id)
    end)

    evicted_pids = Enum.map(evicted, &elem(&1, 0))

    work =
      Enum.reduce(evicted_pids, ParseSync.put_buffers(work, buffers), fn buffer_pid, work ->
        work
        |> ParseSync.release_buffer(buffer_pid)
        |> fail_requests(buffer_pid)
      end)

    {evicted_pids, ParseSync.dispatch_next(work, port)}
  end

  @spec finish_registration(ParseSync.t(), port() | nil, pid(), BufferRegistry.register_status()) ::
          ParseSync.t()
  defp finish_registration(work, _port, buffer_pid, :new) do
    buffers = BufferRegistry.put_monitor(work.buffers, buffer_pid, Process.monitor(buffer_pid))
    ParseSync.put_buffers(work, buffers)
  end

  defp finish_registration(work, _port, _buffer_pid, :existing), do: work

  defp finish_registration(work, port, buffer_pid, {:replaced, old_id}) do
    PortLifecycle.close_buffer(port, old_id)

    work
    |> ParseSync.release_buffer(buffer_pid)
    |> fail_requests(buffer_pid)
  end

  @spec fail_requests(ParseSync.t(), pid()) :: ParseSync.t()
  defp fail_requests(work, buffer_pid) do
    ParseSync.put_requests(work, RequestHandler.fail_buffer(work.requests, buffer_pid))
  end

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
