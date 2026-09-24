defmodule MingaEditor.Renderer.Server do
  @moduledoc """
  Renderer process wrapper.

  All frame, acknowledgement, timeout, and recovery workflows live in focused
  handler modules. This module exposes the process API and keeps OTP callbacks
  as routing-only clauses.
  """

  use GenServer

  alias MingaEditor.Frontend.ResourcePolicy
  alias MingaEditor.Frontend.Manager, as: FrontendManager
  alias MingaEditor.Renderer.Submission
  alias MingaEditor.Renderer.FrameHandler
  alias MingaEditor.Renderer.RecoveryHandler
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.State
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Window

  @type t :: State.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Queues the latest semantic frame submission for asynchronous rendering."
  @spec cast_snapshot(GenServer.server(), Submission.t(), non_neg_integer()) :: :ok
  def cast_snapshot(server \\ __MODULE__, submission, frame_seq)

  def cast_snapshot(server, %Submission{} = submission, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0 do
    GenServer.cast(server, {:render, submission, frame_seq, monotonic_now()})
  end

  @doc "Runs one frame synchronously inside this renderer process."
  @spec render_sync(GenServer.server(), Submission.t(), non_neg_integer()) ::
          {:ok, RenderReceipt.t()} | {:error, Exception.t()}
  def render_sync(server, submission, frame_seq)

  def render_sync(server, %Submission{} = submission, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0 do
    GenServer.call(server, {:render_sync, submission, frame_seq, monotonic_now()}, :infinity)
  end

  @doc "Resets frontend state and renders a synchronous recovery keyframe."
  @spec reset_sync(GenServer.server(), Submission.t(), non_neg_integer()) ::
          {:ok, MingaEditor.Renderer.RenderReceipt.t()} | {:error, Exception.t()}
  def reset_sync(server, %Submission{} = submission, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0 do
    GenServer.call(server, {:reset_sync, submission, frame_seq, monotonic_now()}, :infinity)
  end

  @doc "Renders a synchronous same-connection keyframe while retaining presentation leases."
  @spec reset_keyframe_sync(GenServer.server(), Submission.t(), non_neg_integer()) ::
          {:ok, MingaEditor.Renderer.RenderReceipt.t()} | {:error, Exception.t()}
  def reset_keyframe_sync(server, %Submission{} = submission, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0 do
    GenServer.call(
      server,
      {:reset_keyframe_sync, submission, frame_seq, monotonic_now()},
      :infinity
    )
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

  @doc "Returns the immutable interaction-index reader for this renderer generation."
  @spec text_interaction_reader(GenServer.server()) :: Reader.t()
  def text_interaction_reader(server \\ __MODULE__),
    do: GenServer.call(server, :text_interaction_reader)

  @doc "Records one-shot adaptation evidence without changing the retained source presentation."
  @spec record_adaptation(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          ResourcePolicy.dimension(),
          integer(),
          integer(),
          Submission.t()
        ) :: :ok | :error
  def record_adaptation(
        server \\ __MODULE__,
        generation,
        frame_seq,
        dimension,
        rejected_value,
        adapted_value,
        %Submission{} = adapted_submission
      ) do
    GenServer.call(
      server,
      {:record_adaptation, generation, frame_seq, dimension, rejected_value, adapted_value,
       adapted_submission}
    )
  end

  @doc "Routes a typed frontend frame status to the renderer."
  @spec frame_status(GenServer.server(), MingaEditor.Frontend.Protocol.input_event()) :: :ok
  def frame_status(server \\ __MODULE__, status) do
    send(server, {:frame_status, status})
    :ok
  end

  @doc "Applies one ordered frontend text-presentation lifecycle event."
  @spec text_presentation_state(
          GenServer.server(),
          Window.id(),
          non_neg_integer(),
          :active | :discarded
        ) :: :ok | {:error, :unknown}
  def text_presentation_state(server \\ __MODULE__, window_id, presentation_id, lifecycle) do
    GenServer.call(server, {:text_presentation_state, window_id, presentation_id, lifecycle})
  end

  @doc "Requests recovery only when the failed generation and committed base still match."
  @spec request_recovery(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer()
        ) :: RecoveryHandler.request_result()
  def request_recovery(server \\ __MODULE__, failed_generation, last_applied_frame_seq)
      when is_integer(failed_generation) and failed_generation >= 0 and
             is_integer(last_applied_frame_seq) and last_applied_frame_seq >= 0 do
    GenServer.call(server, {:request_recovery, failed_generation, last_applied_frame_seq})
  end

  @doc "Renders a same-connection keyframe while retaining presentation leases."
  @spec reset_keyframe(GenServer.server(), Submission.t(), non_neg_integer()) :: :ok
  def reset_keyframe(server \\ __MODULE__, submission, frame_seq)

  def reset_keyframe(server, %Submission{} = submission, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0,
      do: GenServer.call(server, {:reset_keyframe, submission, frame_seq, monotonic_now()})

  @doc "Abandons the old frontend connection and renders a fresh keyframe."
  @spec reset_connection(GenServer.server(), Submission.t(), non_neg_integer()) :: :ok
  def reset_connection(server \\ __MODULE__, submission, frame_seq)

  def reset_connection(server, %Submission{} = submission, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0,
      do: GenServer.call(server, {:reset_connection, submission, frame_seq, monotonic_now()})

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    generation_reserver = generation_reserver(opts)
    recovery_generation = generation_reserver.()

    {:ok,
     State.new(
       Keyword.merge(opts,
         generation_reserver: generation_reserver,
         recovery_generation: recovery_generation
       )
     )}
  end

  @impl true
  def handle_call(:rendering?, _from, state), do: {:reply, State.rendering?(state), state}

  def handle_call(:acknowledgement_state, _from, state),
    do:
      {:reply, {state.caches.recovery_generation, state.caches.last_acknowledged_frame_seq},
       state}

  def handle_call(:terminal_failure, _from, state),
    do: {:reply, State.terminal_failure(state), state}

  def handle_call(:text_interaction_reader, _from, state),
    do: {:reply, State.text_interaction_reader(state), state}

  def handle_call(
        {:text_presentation_state, window_id, presentation_id, lifecycle},
        _from,
        state
      ) do
    case State.text_presentation_state(state, window_id, presentation_id, lifecycle) do
      {:ok, updated} -> {:reply, :ok, updated}
      {:error, :unknown, unchanged} -> {:reply, {:error, :unknown}, unchanged}
    end
  end

  def handle_call({:request_recovery, failed_generation, last_applied_frame_seq}, _from, state),
    do: RecoveryHandler.request(state, failed_generation, last_applied_frame_seq)

  def handle_call(
        {:record_adaptation, generation, frame_seq, dimension, rejected_value, adapted_value,
         adapted_submission},
        _from,
        state
      ) do
    FrameHandler.observe_submission(adapted_submission, frame_seq)

    {adapted_intent, _highlights, _semantic_tokens} =
      Submission.materialize(adapted_submission, state.highlights, state.semantic_tokens)

    with {:ok, descriptor} <- ResourcePolicy.adaptation(dimension, rejected_value, adapted_value),
         {:ok, adapted_state} <-
           State.record_adaptation(state, generation, frame_seq, descriptor, adapted_intent) do
      {:reply, :ok, adapted_state}
    else
      :error -> {:reply, :error, state}
      {:error, unchanged} -> {:reply, :error, unchanged}
    end
  end

  def handle_call({:reset_keyframe, submission, seq, pushed_at}, _from, state) do
    {state, intent} = receive_submission(state, submission, seq)
    RecoveryHandler.keyframe(state, intent, seq, pushed_at)
  end

  def handle_call({:reset_keyframe_sync, submission, seq, pushed_at}, _from, state) do
    {state, intent} = receive_submission(state, submission, seq)
    RecoveryHandler.keyframe_sync(state, intent, seq, pushed_at)
  end

  def handle_call({:reset_connection, submission, seq, pushed_at}, _from, state) do
    {state, intent} = receive_submission(state, submission, seq)
    RecoveryHandler.reset(state, intent, seq, pushed_at)
  end

  def handle_call({:reset_sync, submission, seq, pushed_at}, _from, state) do
    {state, intent} = receive_submission(state, submission, seq)
    RecoveryHandler.reset_sync(state, intent, seq, pushed_at)
  end

  def handle_call({:render_sync, submission, seq, pushed_at}, _from, state) do
    {state, intent} = receive_submission(state, submission, seq)
    FrameHandler.render_sync(state, intent, seq, pushed_at)
  end

  @impl true
  def handle_cast({:render, submission, seq, pushed_at}, state) do
    {state, intent} = receive_submission(state, submission, seq)
    FrameHandler.enqueue(state, intent, seq, pushed_at)
  end

  @impl true
  def handle_info(message, state), do: FrameHandler.dispatch(message, state)

  @spec receive_submission(t(), Submission.t(), non_neg_integer()) ::
          {t(), MingaEditor.RenderPipeline.Intent.t()}
  defp receive_submission(state, submission, seq) do
    FrameHandler.observe_submission(submission, seq)
    State.receive_submission(state, submission)
  end

  @spec monotonic_now() :: integer()
  defp monotonic_now, do: System.monotonic_time(:microsecond)

  @spec generation_reserver(keyword()) :: State.generation_reserver()
  defp generation_reserver(opts) do
    case Keyword.fetch(opts, :generation_reserver) do
      {:ok, reserver} when is_function(reserver, 0) ->
        reserver

      :error ->
        default_generation_reserver(opts)
    end
  end

  @spec default_generation_reserver(keyword()) :: State.generation_reserver()
  defp default_generation_reserver(opts) do
    require_ack? = Keyword.get(opts, :require_ack?, not Keyword.has_key?(opts, :pipeline))

    if require_ack? do
      manager = Keyword.get(opts, :frontend_manager, FrontendManager)
      fn -> FrontendManager.reserve_recovery_generation(manager) end
    else
      fn -> 1 end
    end
  end
end
