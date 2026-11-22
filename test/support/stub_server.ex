defmodule Minga.Test.StubServer do
  @moduledoc """
  A minimal GenServer that mimics the Agent.Session API surface.

  Used in tests as a stand-in for a real agent session to avoid starting
  a provider (which spawns OS processes and takes ~700ms). Handles the
  calls that the renderer, agent commands, and buffer management make
  on the session (messages, usage, subscribe, unsubscribe, status, etc.)
  and returns sensible defaults.
  """

  use GenServer

  alias MingaAgent.Session.Transcript
  alias MingaAgent.TurnUsage

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts), do: {:ok, Map.new(opts)}

  @impl GenServer
  def handle_call(:messages, _from, state), do: {:reply, Map.get(state, :messages, []), state}

  def handle_call(:messages_with_ids, _from, state) do
    messages = Map.get(state, :messages, [])
    pairs = Map.get_lazy(state, :message_ids, fn -> default_message_ids(messages) end)
    {:reply, pairs, state}
  end

  def handle_call(:pinned_ids, _from, state),
    do: {:reply, Map.get(state, :pinned_ids, MapSet.new()), state}

  def handle_call({:transcript_since, cursor}, _from, state) do
    {transcript, state} = fixture_transcript(state)
    {:reply, Transcript.since(transcript, cursor), state}
  end

  def handle_call({:editor_arrival, cursor, subscriber, token}, from, state) do
    case Map.fetch(state, :arrival_observer) do
      {:ok, observer} ->
        send(observer, {:capture_requested, self(), token})
        {:noreply, Map.put(state, :pending_capture, {cursor, subscriber, token, from})}

      :error ->
        {:reply, :forwarded, forward_arrival(state, cursor, subscriber, token)}
    end
  end

  def handle_call(
        {:release_capture, snapshot, before_fence},
        _from,
        %{pending_capture: pending} = state
      ) do
    {cursor, subscriber, token, from} = pending
    Enum.each(before_fence, &send(subscriber, {:agent_event, self(), &1}))
    state = Map.merge(Map.delete(state, :pending_capture), snapshot)
    state = forward_arrival(state, cursor, subscriber, token)
    GenServer.reply(from, :forwarded)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, _pid, _opts}, _from, state), do: {:reply, :ok, state}

  def handle_call({:toggle_pin, id}, _from, state) do
    pinned_ids = Map.get(state, :pinned_ids, MapSet.new())
    pinned_ids = toggle_pinned_id(pinned_ids, id)
    {:reply, :ok, Map.put(state, :pinned_ids, pinned_ids)}
  end

  def handle_call(:usage, _from, state),
    do: {:reply, %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}, state}

  def handle_call(:status, _from, state), do: {:reply, Map.get(state, :status, :idle), state}

  def handle_call(:model_selection, _from, state),
    do: {:reply, Map.get(state, :model_selection), state}

  def handle_call({:subscribe, _pid}, _from, state), do: {:reply, :ok, state}
  def handle_call({:unsubscribe, _pid}, _from, state), do: {:reply, :ok, state}

  def handle_call(:editor_snapshot, _from, state), do: {:reply, fixture_snapshot(state), state}

  def handle_call({:load_session, session_id, nil}, _from, state) do
    case Map.get(state, :load_result, :ok) do
      :ok ->
        case Map.get(state, :notify) do
          pid when is_pid(pid) -> send(pid, {:stub_loaded_session, session_id})
          _ -> :ok
        end

        {:reply, :ok, Map.put(state, :loaded_session, session_id)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # Opt-in provider fixtures: `provider:` answers Session.get_provider/1, and
  # `refresh_to:` makes this stub act as a provider that reports each refreshed
  # project view to the given pid.
  def handle_call(:get_provider, _from, %{provider: provider} = state),
    do: {:reply, provider, state}

  def handle_call({:refresh_project_view, view}, _from, %{refresh_to: pid} = state) do
    send(pid, {:provider_project_view_refreshed, self(), view})
    {:reply, Map.get(state, :refresh_reply, :ok), state}
  end

  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  # The stand-in sees one canonical transcript and snapshot for all of its Editor readers.
  defp fixture_transcript(state) do
    messages = Map.get(state, :messages, [])
    pairs = Map.get_lazy(state, :message_ids, fn -> default_message_ids(messages) end)
    pins = Map.get(state, :pinned_ids, MapSet.new())
    source = {messages, pairs, pins}

    transcript =
      case Map.get(state, :transcript_fixture) do
        {^source, transcript} ->
          transcript

        previous ->
          now = DateTime.utc_now()

          transcript =
            if previous, do: elem(previous, 1), else: Transcript.new([], now, make_ref())

          ids = Enum.map(pairs, &elem(&1, 0))
          Transcript.restore(transcript, messages, ids, [], TurnUsage.new(), pins, now)
      end

    {transcript, Map.put(state, :transcript_fixture, {source, transcript})}
  end

  defp forward_arrival(state, cursor, subscriber, token) do
    {transcript, state} = fixture_transcript(state)

    capture =
      case Transcript.since(transcript, cursor) do
        {:unchanged, cursor} -> {:unchanged, cursor}
        {:changes, changes} -> {:changes, changes}
        {:snapshot, snapshot} -> {:replace, :changed, snapshot, nil}
        {:reset, _reason, snapshot} -> {:replace, :reset, snapshot, nil}
      end

    send(
      subscriber,
      {:agent_event, self(), {:editor_arrival_ready, token, {fixture_snapshot(state), capture}}}
    )

    state
  end

  defp fixture_snapshot(state) do
    status = Map.get(state, :status, :idle)

    %{
      status: status,
      display_status: Map.get(state, :display_status, status),
      pending_approval: Map.get(state, :pending_approval),
      error: Map.get(state, :error),
      active_tool_name: Map.get(state, :active_tool_name),
      connection: Map.get(state, :connection)
    }
  end

  @spec toggle_pinned_id(MapSet.t(pos_integer()), pos_integer()) :: MapSet.t(pos_integer())
  defp toggle_pinned_id(pinned_ids, id) do
    if MapSet.member?(pinned_ids, id) do
      MapSet.delete(pinned_ids, id)
    else
      MapSet.put(pinned_ids, id)
    end
  end

  @spec default_message_ids([term()]) :: [{pos_integer(), term()}]
  defp default_message_ids(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map(fn {msg, id} -> {id, msg} end)
  end

  @impl GenServer
  def handle_cast({:add_system_message, text, level}, state) do
    case Map.get(state, :notify) do
      pid when is_pid(pid) -> send(pid, {:stub_system_message, text, level})
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
