defmodule Minga.Parser.RequestHandler do
  @moduledoc """
  Focused handlers for sequence-fenced synchronous parser requests.

  The manager installs returned request and buffer aggregates. This module owns
  the ordering of buffer snapshots, Port writes, request timers, and replies.
  """

  alias Minga.Buffer
  alias Minga.Buffer.SyncSnapshot
  alias Minga.Parser.BufferRegistration
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.RequestState

  @type command_builder :: RequestState.command_builder()
  @type enqueue_result :: {:noreply, RequestState.t()} | {:reply, nil, RequestState.t()}
  @type snapshot_result ::
          {:handled, RequestState.t(), BufferRegistry.t(), pid()} | :unhandled

  @doc "Begins an atomic sequence fence for a synchronous parser-backed request."
  @spec enqueue(
          port() | nil,
          BufferRegistry.t(),
          RequestState.t(),
          pid(),
          GenServer.from(),
          pos_integer(),
          command_builder()
        ) :: enqueue_result()
  def enqueue(nil, _buffers, requests, _buffer_pid, _from, _timeout_ms, _builder),
    do: {:reply, nil, requests}

  def enqueue(_port, buffers, requests, buffer_pid, from, timeout_ms, command_builder) do
    case BufferRegistry.fetch(buffers, buffer_pid) do
      {:ok, registration} ->
        token = make_ref()

        :ok =
          Buffer.request_sync_snapshot(buffer_pid, registration.synced_sequence, self(), token)

        Process.send_after(self(), {:buffer_request_timeout, token}, timeout_ms)

        request = %{
          from: from,
          buffer: buffer_pid,
          command_builder: command_builder,
          required_sequence: nil
        }

        {:noreply, RequestState.defer(requests, token, request)}

      :error ->
        {:reply, nil, requests}
    end
  end

  @doc "Consumes a request-fence snapshot and records its required sequence."
  @spec handle_snapshot(RequestState.t(), BufferRegistry.t(), SyncSnapshot.t()) ::
          snapshot_result()
  def handle_snapshot(requests, buffers, %SyncSnapshot{
        token: token,
        buffer: buffer_pid,
        sequence: sequence
      }) do
    case RequestState.satisfy_fence(requests, token, buffer_pid, sequence) do
      {:ok, requests} ->
        buffers =
          case BufferRegistry.fetch(buffers, buffer_pid) do
            {:ok, registration} ->
              BufferRegistry.put(
                buffers,
                buffer_pid,
                BufferRegistration.mark_dirty(registration, sequence)
              )

            :error ->
              buffers
          end

        {:handled, requests, buffers, buffer_pid}

      :stale ->
        :unhandled
    end
  end

  @doc "Emits all deferred requests whose sequence fence has been satisfied."
  @spec flush_buffer(port() | nil, RequestState.t(), BufferRegistry.t(), pid()) ::
          RequestState.t()
  def flush_buffer(port, requests, buffers, buffer_pid) do
    case BufferRegistry.fetch(buffers, buffer_pid) do
      {:ok, registration} -> flush_ready(port, requests, buffer_pid, registration)
      :error -> fail_buffer(requests, buffer_pid)
    end
  end

  @doc "Replies nil to a timed-out deferred or in-flight request."
  @spec timeout(RequestState.t(), reference()) :: RequestState.t()
  def timeout(requests, token) do
    case RequestState.pop_deferred(requests, token) do
      {nil, requests} ->
        timeout_in_flight(requests, token)

      {request, requests} ->
        GenServer.reply(request.from, nil)
        RequestState.drop_fence(requests, token)
    end
  end

  @doc "Replies to a parser result and removes its in-flight request."
  @spec reply(RequestState.t(), non_neg_integer(), term()) :: {:noreply, RequestState.t()}
  def reply(requests, request_id, result) do
    case RequestState.pop_in_flight(requests, request_id) do
      {nil, _requests} ->
        {:noreply, requests}

      {request, requests} ->
        GenServer.reply(request.from, result)
        {:noreply, requests}
    end
  end

  @doc "Fails deferred, fenced, and in-flight requests associated with one buffer."
  @spec fail_buffer(RequestState.t(), pid()) :: RequestState.t()
  def fail_buffer(requests, buffer_pid) do
    {replies, requests} = RequestState.take_buffer(requests, buffer_pid)
    Enum.each(replies, &GenServer.reply(&1, nil))
    requests
  end

  @doc "Fails every sequence-fenced and parser-in-flight buffer request."
  @spec fail_all(RequestState.t()) :: RequestState.t()
  def fail_all(requests) do
    {replies, requests} = RequestState.take_all(requests)
    Enum.each(replies, &GenServer.reply(&1, nil))
    requests
  end

  @spec flush_ready(port() | nil, RequestState.t(), pid(), BufferRegistration.t()) ::
          RequestState.t()
  defp flush_ready(port, requests, buffer_pid, registration) do
    ready? = fn request ->
      is_integer(request.required_sequence) and
        BufferRegistration.synchronized?(registration, request.required_sequence)
    end

    {ready, requests} = RequestState.take_ready(requests, buffer_pid, ready?)
    Enum.reduce(ready, requests, &emit_request(port, registration, &1, &2))
  end

  @spec emit_request(
          port() | nil,
          BufferRegistration.t(),
          {reference(), RequestState.deferred_request()},
          RequestState.t()
        ) :: RequestState.t()
  defp emit_request(port, registration, {token, request}, requests) do
    request_id = RequestState.next_id(requests)
    command = request.command_builder.(registration.id, request_id)

    if send_command(port, command) do
      pending = %{from: request.from, buffer: request.buffer, token: token}
      {_id, requests} = RequestState.emit(requests, pending)
      requests
    else
      GenServer.reply(request.from, nil)
      requests
    end
  end

  @spec timeout_in_flight(RequestState.t(), reference()) :: RequestState.t()
  defp timeout_in_flight(requests, token) do
    case RequestState.pop_in_flight_by_token(requests, token) do
      {nil, requests} ->
        requests

      {request, requests} ->
        GenServer.reply(request.from, nil)
        requests
    end
  end

  @spec send_command(port() | nil, binary()) :: boolean()
  defp send_command(nil, _command), do: false

  defp send_command(port, command) do
    Port.command(port, command)
  rescue
    ArgumentError -> false
  catch
    :exit, _reason -> false
  end
end
