defmodule MingaEditor.Renderer.Server do
  @moduledoc """
  Renderer process wrapper.

  All frame, acknowledgement, timeout, and recovery workflows live in focused
  handler modules. This module exposes the process API and keeps OTP callbacks
  as routing-only clauses.
  """

  use GenServer

  alias MingaEditor.Frontend.ResourcePolicy
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.FrameHandler
  alias MingaEditor.Renderer.RecoveryHandler
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.State

  @type t :: State.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Queues the latest semantic frame intent for asynchronous rendering."
  @spec cast_snapshot(GenServer.server(), Intent.t(), non_neg_integer()) :: :ok
  def cast_snapshot(server \\ __MODULE__, intent, frame_seq)

  def cast_snapshot(server, %Intent{} = intent, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0 do
    GenServer.cast(server, {:render, intent, frame_seq, monotonic_now()})
  end

  @doc "Runs one frame synchronously inside this renderer process."
  @spec render_sync(GenServer.server(), Intent.t(), non_neg_integer()) ::
          {:ok, RenderReceipt.t()} | {:error, Exception.t()}
  def render_sync(server, intent, frame_seq)

  def render_sync(server, %Intent{} = intent, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0 do
    GenServer.call(server, {:render_sync, intent, frame_seq, monotonic_now()}, :infinity)
  end

  @doc "Resets frontend state and renders a synchronous recovery keyframe."
  @spec reset_sync(GenServer.server(), Intent.t(), non_neg_integer()) ::
          {:ok, MingaEditor.Renderer.RenderReceipt.t()} | {:error, Exception.t()}
  def reset_sync(server, %Intent{} = intent, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0 do
    GenServer.call(server, {:reset_sync, intent, frame_seq, monotonic_now()}, :infinity)
  end

  @doc "Returns true while rendering or awaiting frontend credit."
  @spec rendering?(GenServer.server()) :: boolean()
  def rendering?(server \\ __MODULE__), do: GenServer.call(server, :rendering?)

  @doc "Returns current recovery generation and acknowledged frame sequence."
  @spec acknowledgement_state(GenServer.server()) :: {non_neg_integer(), non_neg_integer()}
  def acknowledgement_state(server \\ __MODULE__),
    do: GenServer.call(server, :acknowledgement_state)

  @doc "Returns the visible terminal frontend failure, if one has stopped frame credit."
  @spec terminal_failure(GenServer.server()) ::
          MingaEditor.Renderer.RejectionState.terminal() | nil
  def terminal_failure(server \\ __MODULE__), do: GenServer.call(server, :terminal_failure)

  @doc "Records one-shot adaptation evidence bound to an outstanding rejected transaction."
  @spec record_adaptation(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          ResourcePolicy.dimension(),
          integer(),
          integer(),
          Intent.t()
        ) :: :ok | :error
  def record_adaptation(
        server \\ __MODULE__,
        generation,
        frame_seq,
        dimension,
        rejected_value,
        adapted_value,
        %Intent{} = adapted_intent
      ) do
    GenServer.call(
      server,
      {:record_adaptation, generation, frame_seq, dimension, rejected_value, adapted_value,
       adapted_intent}
    )
  end

  @doc "Routes a typed frontend frame status to the renderer."
  @spec frame_status(GenServer.server(), MingaEditor.Frontend.Protocol.input_event()) :: :ok
  def frame_status(server \\ __MODULE__, status) do
    send(server, {:frame_status, status})
    :ok
  end

  @doc "Requests recovery of the outstanding renderer transaction."
  @spec request_recovery(GenServer.server()) :: :ok
  def request_recovery(server \\ __MODULE__) do
    send(server, :request_recovery)
    :ok
  end

  @doc "Abandons the old frontend connection and renders a fresh keyframe."
  @spec reset_connection(GenServer.server(), Intent.t(), non_neg_integer()) :: :ok
  def reset_connection(server \\ __MODULE__, intent, frame_seq)

  def reset_connection(server, %Intent{} = intent, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0,
      do: GenServer.call(server, {:reset_connection, intent, frame_seq, monotonic_now()})

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts), do: {:ok, State.new(opts)}

  @impl true
  def handle_call(:rendering?, _from, state), do: {:reply, State.rendering?(state), state}

  def handle_call(:acknowledgement_state, _from, state),
    do:
      {:reply, {state.caches.recovery_generation, state.caches.last_acknowledged_frame_seq},
       state}

  def handle_call(:terminal_failure, _from, state),
    do: {:reply, State.terminal_failure(state), state}

  def handle_call(
        {:record_adaptation, generation, frame_seq, dimension, rejected_value, adapted_value,
         adapted_intent},
        _from,
        state
      ) do
    with {:ok, descriptor} <- ResourcePolicy.adaptation(dimension, rejected_value, adapted_value),
         {:ok, adapted_state} <-
           State.record_adaptation(state, generation, frame_seq, descriptor, adapted_intent) do
      {:reply, :ok, adapted_state}
    else
      :error -> {:reply, :error, state}
      {:error, unchanged} -> {:reply, :error, unchanged}
    end
  end

  def handle_call({:reset_connection, intent, seq, pushed_at}, _from, state),
    do: RecoveryHandler.reset(state, intent, seq, pushed_at)

  def handle_call({:reset_sync, intent, seq, pushed_at}, _from, state),
    do: RecoveryHandler.reset_sync(state, intent, seq, pushed_at)

  def handle_call({:render_sync, intent, seq, pushed_at}, _from, state),
    do: FrameHandler.render_sync(state, intent, seq, pushed_at)

  @impl true
  def handle_cast({:render, intent, seq, pushed_at}, state),
    do: FrameHandler.enqueue(state, intent, seq, pushed_at)

  @impl true
  def handle_info(message, state), do: FrameHandler.dispatch(message, state)

  @spec monotonic_now() :: integer()
  defp monotonic_now, do: System.monotonic_time(:microsecond)
end
