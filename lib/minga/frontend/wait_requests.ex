defmodule Minga.Frontend.WaitRequests do
  @moduledoc """
  Tracks native CLI wait requests against the exact buffer target they opened.

  Requests are completed from source-owned buffer save events or explicit editor
  close/abort paths. The tracker never owns transport files: completion is sent
  directly to the authenticated native IPC connection that registered it.
  """

  use GenServer

  alias Minga.Events
  alias Minga.Frontend.WaitRequestCompletion
  alias Minga.Frontend.WaitRequests.State

  @typedoc "Wait request completion status."
  @type completion :: WaitRequestCompletion.outcome()

  @typedoc "Server option."
  @type start_opt ::
          {:name, GenServer.name() | nil}
          | {:events_registry, Events.registry()}

  @typep entry :: State.entry()
  @typep request :: State.request()

  @doc "Starts the wait-request tracker."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Registers an opened target for completion on the supplied IPC connection."
  @spec register(pid(), String.t(), String.t(), pid(), GenServer.server()) ::
          :ok | {:error, term()}
  def register(buffer, target_path, request_id, waiter, server \\ __MODULE__)
      when is_pid(buffer) and is_binary(target_path) and is_binary(request_id) and
             is_pid(waiter) do
    call(
      server,
      {:register, buffer, Path.expand(target_path), request_id, waiter},
      {:error, :wait_tracker_unavailable}
    )
  end

  @doc "Completes requests matching the buffer's current target successfully."
  @spec accept(pid(), String.t(), GenServer.server()) :: :ok
  def accept(buffer, path, server \\ __MODULE__) when is_pid(buffer) and is_binary(path) do
    call(server, {:accept, buffer, path}, :ok)
  end

  @doc "Completes a clean close, accepting matching targets and cancelling stale ones."
  @spec close(pid(), String.t(), GenServer.server()) :: :ok
  def close(buffer, path, server \\ __MODULE__) when is_pid(buffer) and is_binary(path) do
    call(server, {:close, buffer, path}, :ok)
  end

  @doc "Completes all requests for a buffer as cancelled."
  @spec cancel(pid(), String.t(), GenServer.server()) :: :ok
  def cancel(buffer, reason, server \\ __MODULE__)
      when is_pid(buffer) and is_binary(reason) do
    call(server, {:cancel, buffer, reason}, :ok)
  end

  @doc "Completes every clean matching request and cancels stale target requests."
  @spec accept_all(GenServer.server()) :: :ok
  def accept_all(server \\ __MODULE__), do: call(server, :accept_all, :ok)

  @doc "Completes every outstanding request as cancelled."
  @spec cancel_all(String.t(), GenServer.server()) :: :ok
  def cancel_all(reason, server \\ __MODULE__) when is_binary(reason) do
    call(server, {:complete_all, {:cancelled, reason}}, :ok)
  end

  @doc "Acknowledges that the native client received a terminal completion frame."
  @spec acknowledge(String.t(), GenServer.server()) :: :ok
  def acknowledge(request_id, server \\ __MODULE__) when is_binary(request_id) do
    call(server, {:acknowledge, request_id}, :ok)
  end

  @doc "Waits until every emitted terminal completion frame is acknowledged."
  @spec await_acknowledgements(timeout(), GenServer.server()) :: :ok | {:error, :timeout}
  def await_acknowledgements(timeout \\ 2_000, server \\ __MODULE__)
      when is_integer(timeout) and timeout >= 0 do
    call(server, {:await_acknowledgements, timeout}, :ok)
  end

  @spec call(GenServer.server(), term(), term()) :: term()
  defp call(server, message, fallback) do
    case GenServer.whereis(server) do
      nil -> fallback
      _pid -> GenServer.call(server, message)
    end
  end

  @impl true
  @spec init([start_opt()]) :: {:ok, State.t()}
  def init(opts) do
    events_registry = Keyword.get(opts, :events_registry, Events.default_registry())
    :ok = Events.subscribe(:buffer_saved, events_registry)

    {:ok, State.new(events_registry)}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), State.t()) ::
          {:reply, term(), State.t()} | {:noreply, State.t()}
  def handle_call({:register, buffer, target, request_id, waiter}, _from, state) do
    entry = %{target: target, waiter: waiter, waiter_monitor: Process.monitor(waiter)}
    requests = put_request(state.requests, buffer, request_id, entry)
    {:reply, :ok, State.requests_updated(state, requests)}
  end

  def handle_call({:accept, buffer, path}, _from, state) do
    {:reply, :ok, complete_matching(state, buffer, path, :accepted)}
  end

  def handle_call({:close, buffer, path}, _from, state) do
    state = complete_matching(state, buffer, path, :accepted)
    {:reply, :ok, complete_buffer(state, buffer, {:cancelled, "requested target was retargeted"})}
  end

  def handle_call({:cancel, buffer, reason}, _from, state) do
    {:reply, :ok, complete_buffer(state, buffer, {:cancelled, reason})}
  end

  def handle_call(:accept_all, _from, state) do
    state = Enum.reduce(Map.keys(state.requests), state, &complete_for_shutdown/2)
    {:reply, :ok, state}
  end

  def handle_call({:complete_all, completion}, _from, state) do
    state = Enum.reduce(Map.keys(state.requests), state, &complete_buffer(&2, &1, completion))
    {:reply, :ok, state}
  end

  def handle_call({:acknowledge, request_id}, _from, state) do
    {:reply, :ok, acknowledge_pending(state, request_id)}
  end

  def handle_call(
        {:await_acknowledgements, _timeout},
        _from,
        %State{pending_acks: pending} = state
      )
      when map_size(pending) == 0 do
    {:reply, :ok, state}
  end

  def handle_call({:await_acknowledgements, timeout}, from, state) do
    timer = Process.send_after(self(), {:ack_timeout, from}, timeout)
    {:noreply, State.drain_waiter_added(state, {from, timer})}
  end

  @impl true
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()}
  def handle_info(
        {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: buffer, path: path}},
        state
      ) do
    {:noreply, complete_matching(state, buffer, path, :accepted)}
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case buffer_for_monitor(state.requests, monitor, pid) do
      {:ok, buffer} ->
        completion = {:cancelled, "buffer exited before wait completion: #{inspect(reason)}"}
        {:noreply, complete_buffer(state, buffer, completion)}

      :error ->
        {:noreply, remove_waiter(state, monitor, pid)}
    end
  end

  def handle_info({:ack_timeout, from}, state) do
    case List.keytake(state.drain_waiters, from, 0) do
      {{^from, _timer}, remaining} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, State.drain_waiter_timed_out(state, remaining)}

      nil ->
        {:noreply, state}
    end
  end

  @spec put_request(%{optional(pid()) => request()}, pid(), String.t(), entry()) :: %{
          optional(pid()) => request()
        }
  defp put_request(requests, buffer, request_id, entry) do
    case Map.get(requests, buffer) do
      nil ->
        Map.put(requests, buffer, %{
          buffer_monitor: Process.monitor(buffer),
          entries: %{request_id => entry}
        })

      request ->
        Map.put(requests, buffer, %{
          request
          | entries: Map.put(request.entries, request_id, entry)
        })
    end
  end

  @spec complete_for_shutdown(pid(), State.t()) :: State.t()
  defp complete_for_shutdown(buffer, state) do
    case current_buffer_status(buffer) do
      {:ok, path, false} ->
        state
        |> complete_matching(buffer, path, :accepted)
        |> complete_buffer(buffer, {:cancelled, "requested target was retargeted"})

      {:ok, path, true} ->
        state
        |> complete_matching(
          buffer,
          path,
          {:cancelled, "buffer has unsaved changes at editor shutdown"}
        )
        |> complete_buffer(buffer, {:cancelled, "requested target was retargeted"})

      :error ->
        complete_buffer(state, buffer, {:cancelled, "buffer unavailable at editor shutdown"})
    end
  end

  @spec complete_matching(State.t(), pid(), String.t(), completion()) :: State.t()
  defp complete_matching(state, buffer, path, completion) do
    case Map.get(state.requests, buffer) do
      nil ->
        state

      request ->
        canonical_path = Path.expand(path)

        {matching, remaining} =
          Map.split_with(request.entries, fn {_id, entry} -> entry.target == canonical_path end)

        state
        |> update_request(buffer, request, remaining)
        |> complete_entries(matching, completion)
    end
  end

  @spec complete_buffer(State.t(), pid(), completion()) :: State.t()
  defp complete_buffer(state, buffer, completion) do
    case Map.pop(state.requests, buffer) do
      {nil, _requests} ->
        state

      {request, requests} ->
        Process.demonitor(request.buffer_monitor, [:flush])

        state
        |> State.requests_updated(requests)
        |> complete_entries(request.entries, completion)
    end
  end

  @spec update_request(State.t(), pid(), request(), %{String.t() => entry()}) :: State.t()
  defp update_request(state, buffer, request, entries) when map_size(entries) == 0 do
    Process.demonitor(request.buffer_monitor, [:flush])
    State.requests_updated(state, Map.delete(state.requests, buffer))
  end

  defp update_request(state, buffer, request, entries) do
    requests = Map.put(state.requests, buffer, %{request | entries: entries})
    State.requests_updated(state, requests)
  end

  @spec complete_entries(State.t(), %{String.t() => entry()}, completion()) :: State.t()
  defp complete_entries(state, entries, completion) do
    pending_acks =
      Enum.reduce(entries, state.pending_acks, fn {request_id, entry}, pending ->
        send(entry.waiter, WaitRequestCompletion.new(request_id, completion))

        Map.put(pending, request_id, %{
          waiter: entry.waiter,
          waiter_monitor: entry.waiter_monitor
        })
      end)

    State.completions_emitted(state, pending_acks)
  end

  @spec buffer_for_monitor(%{optional(pid()) => request()}, reference(), pid()) ::
          {:ok, pid()} | :error
  defp buffer_for_monitor(requests, monitor, pid) do
    case Enum.find(requests, fn {buffer, request} ->
           buffer == pid and request.buffer_monitor == monitor
         end) do
      {buffer, _request} -> {:ok, buffer}
      nil -> :error
    end
  end

  @spec remove_waiter(State.t(), reference(), pid()) :: State.t()
  defp remove_waiter(state, monitor, waiter) do
    state =
      Enum.reduce(state.requests, state, fn {buffer, request}, acc ->
        entries =
          Map.reject(request.entries, fn {_id, entry} ->
            entry.waiter == waiter and entry.waiter_monitor == monitor
          end)

        update_request(acc, buffer, request, entries)
      end)

    pending_acks =
      Map.reject(state.pending_acks, fn {_id, pending} ->
        pending.waiter == waiter and pending.waiter_monitor == monitor
      end)

    state
    |> State.waiter_removed(state.requests, pending_acks)
    |> maybe_reply_drain_waiters()
  end

  @spec acknowledge_pending(State.t(), String.t()) :: State.t()
  defp acknowledge_pending(state, request_id) do
    case Map.pop(state.pending_acks, request_id) do
      {nil, _pending} ->
        state

      {pending, remaining} ->
        Process.demonitor(pending.waiter_monitor, [:flush])
        state |> State.acknowledgement_received(remaining) |> maybe_reply_drain_waiters()
    end
  end

  @spec maybe_reply_drain_waiters(State.t()) :: State.t()
  defp maybe_reply_drain_waiters(%State{pending_acks: pending} = state)
       when map_size(pending) == 0 do
    Enum.each(state.drain_waiters, fn {from, timer} ->
      _ = Process.cancel_timer(timer)
      GenServer.reply(from, :ok)
    end)

    State.drain_completed(state)
  end

  defp maybe_reply_drain_waiters(state), do: state

  @spec current_buffer_status(pid()) :: {:ok, String.t(), boolean()} | :error
  defp current_buffer_status(buffer) do
    case Minga.Buffer.file_path(buffer) do
      path when is_binary(path) -> {:ok, path, Minga.Buffer.dirty?(buffer)}
      _other -> :error
    end
  catch
    :exit, _ -> :error
  end
end
