defmodule MingaEditor.Renderer.State do
  @moduledoc """
  Complete long-lived state owned by `MingaEditor.Renderer.Server`.

  Renderer caches, font registration, frontend acknowledgement state, resident
  windows, observed buffer monitors, and coalesced frame credit live here. Public
  transitions centralize lifecycle cleanup so window close, buffer replacement,
  reset, and exact monitor `:DOWN` all discard the same state.
  """

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.ResourcePolicy
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.AckLease
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Renderer.RejectionState
  alias MingaEditor.Renderer.ObservedBuffers
  alias MingaEditor.Renderer.ResidentWindowState
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.Window

  @type editor_ref :: pid() | atom() | nil
  @type pipeline :: (Input.t() -> Input.t())

  @type frame_successor :: FrameAttempt.t()
  @type frame_credit ::
          :idle
          | {:scheduled, reference(), FrameAttempt.t(), non_neg_integer(),
             frame_successor() | nil}
          | {:awaiting_ack, AckLease.t(), frame_successor() | nil}

  @type t :: %__MODULE__{
          editor_pid: editor_ref(),
          frame_credit: frame_credit(),
          ack_timeout_ms: pos_integer(),
          font_registry: FontRegistry.t(),
          caches: Caches.t(),
          message_store: MessageStore.t() | nil,
          resident_windows: %{optional(Window.id()) => ResidentWindowState.t()},
          observed_buffers: ObservedBuffers.t(),
          pipeline: pipeline(),
          require_ack?: boolean(),
          rejection_state: RejectionState.t()
        }

  defstruct editor_pid: nil,
            frame_credit: :idle,
            ack_timeout_ms: 2_000,
            font_registry: FontRegistry.new(),
            caches: Caches.new(),
            message_store: nil,
            resident_windows: %{},
            observed_buffers: ObservedBuffers.new(),
            pipeline: &RenderPipeline.run/1,
            require_ack?: true,
            rejection_state: RejectionState.new()

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      editor_pid: Keyword.get(opts, :editor_pid, MingaEditor),
      pipeline: Keyword.get(opts, :pipeline, &RenderPipeline.run/1),
      require_ack?: Keyword.get(opts, :require_ack?, not Keyword.has_key?(opts, :pipeline)),
      ack_timeout_ms: Keyword.get(opts, :ack_timeout_ms, 2_000)
    }
  end

  @spec accept_intent(t(), Intent.t()) :: {:accepted, t()} | {:blocked, t()}
  def accept_intent(%__MODULE__{} = state, %Intent{} = intent) do
    if RejectionState.blocks?(state.rejection_state, intent) do
      {:blocked, state}
    else
      {:accepted, %{state | rejection_state: RejectionState.clear(state.rejection_state)}}
    end
  end

  @spec rendering?(t()) :: boolean()
  def rendering?(%__MODULE__{frame_credit: :idle}), do: false
  def rendering?(%__MODULE__{}), do: true

  @spec awaiting_lease(t()) :: AckLease.t() | nil
  def awaiting_lease(%__MODULE__{frame_credit: {:awaiting_ack, %AckLease{} = lease, _successor}}),
    do: lease

  def awaiting_lease(%__MODULE__{}), do: nil

  @spec schedule_frame(t(), FrameAttempt.t(), reference()) :: t()
  def schedule_frame(%__MODULE__{} = state, %FrameAttempt{} = attempt, token)
      when is_reference(token) do
    %{state | frame_credit: {:scheduled, token, attempt, 0, nil}}
  end

  @spec coalesce_frame(t(), FrameAttempt.t()) ::
          :idle | {:coalesced, t(), FrameAttempt.t() | nil}
  def coalesce_frame(%__MODULE__{frame_credit: :idle}, %FrameAttempt{}), do: :idle

  def coalesce_frame(
        %__MODULE__{frame_credit: {:scheduled, token, current, retry_count, successor}} = state,
        %FrameAttempt{} = attempt
      ) do
    {:coalesced, %{state | frame_credit: {:scheduled, token, current, retry_count, attempt}},
     successor}
  end

  def coalesce_frame(
        %__MODULE__{frame_credit: {:awaiting_ack, lease, successor}} = state,
        %FrameAttempt{} = attempt
      ) do
    {:coalesced, %{state | frame_credit: {:awaiting_ack, lease, attempt}}, successor}
  end

  @spec consume_render_token(t(), reference()) ::
          {:ok, t(), FrameAttempt.t(), non_neg_integer()} | :stale
  def consume_render_token(
        %__MODULE__{frame_credit: {:scheduled, token, %FrameAttempt{} = attempt, retry_count, _}} =
          state,
        token
      )
      when is_reference(token) do
    {:ok, state, attempt, retry_count}
  end

  def consume_render_token(%__MODULE__{}, token) when is_reference(token), do: :stale

  @spec await_ack(t(), AckLease.t()) :: t()
  def await_ack(
        %__MODULE__{frame_credit: {:scheduled, _token, _attempt, _retry_count, successor}} = state,
        %AckLease{} = lease
      ) do
    %{state | frame_credit: {:awaiting_ack, lease, successor}}
  end

  @spec advance_credit(t()) :: {:idle, t()} | {:schedule, t(), FrameAttempt.t()}
  def advance_credit(%__MODULE__{frame_credit: :idle} = state), do: {:idle, state}

  def advance_credit(%__MODULE__{frame_credit: {:scheduled, _, _, _, successor}} = state),
    do: advance_successor(%{state | frame_credit: :idle}, successor)

  def advance_credit(%__MODULE__{frame_credit: {:awaiting_ack, _, successor}} = state),
    do: advance_successor(%{state | frame_credit: :idle}, successor)

  @spec retry_scheduled_frame(t(), reference()) :: t()
  def retry_scheduled_frame(
        %__MODULE__{frame_credit: {:scheduled, _old_token, attempt, retry_count, successor}} =
          state,
        token
      )
      when is_reference(token) do
    %{state | frame_credit: {:scheduled, token, attempt, retry_count + 1, successor}}
  end

  @spec latest_successor(t(), FrameAttempt.t()) :: FrameAttempt.t()
  def latest_successor(%__MODULE__{frame_credit: {:scheduled, _, _, _, successor}}, fallback),
    do: FrameAttempt.latest(successor, fallback)

  def latest_successor(%__MODULE__{frame_credit: {:awaiting_ack, _, successor}}, fallback),
    do: FrameAttempt.latest(successor, fallback)

  def latest_successor(%__MODULE__{frame_credit: :idle}, fallback),
    do: FrameAttempt.latest(nil, fallback)

  @spec record_adaptation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          ResourcePolicy.adaptation_descriptor(),
          Intent.t()
        ) :: {:ok, t()} | {:error, t()}
  def record_adaptation(
        %__MODULE__{frame_credit: {:awaiting_ack, %AckLease{} = lease, _successor}} = state,
        generation,
        frame_seq,
        %{dimension: dimension} = descriptor,
        %Intent{} = adapted
      )
      when lease.generation == generation and lease.attempt.seq == frame_seq and
             adapted != lease.attempt.intent do
    rejected = lease.attempt.intent

    if advertised_dimension?(rejected, dimension) do
      rejection_state =
        RejectionState.adapt(state.rejection_state, generation, frame_seq, descriptor, adapted)

      {:ok, %{state | rejection_state: rejection_state}}
    else
      {:error, state}
    end
  end

  def record_adaptation(%__MODULE__{} = state, _generation, _frame_seq, _descriptor, %Intent{}),
    do: {:error, state}

  @spec terminal_failure(t(), non_neg_integer(), atom()) :: t()
  def terminal_failure(
        %__MODULE__{frame_credit: {:awaiting_ack, %AckLease{} = lease, _successor}} = state,
        last_good_frame_seq,
        reason
      ) do
    rejection_state =
      RejectionState.terminal(
        state.rejection_state,
        lease.generation,
        lease.attempt.seq,
        last_good_frame_seq,
        reason,
        lease.attempt.intent
      )

    %{state | frame_credit: :idle, rejection_state: rejection_state}
  end

  @spec terminal_failure(t()) :: RejectionState.terminal() | nil
  def terminal_failure(%__MODULE__{} = state), do: state.rejection_state.terminal

  @spec consume_adaptation(t(), AckLease.t()) :: {:ok, t(), Intent.t()} | :error
  def consume_adaptation(
        %__MODULE__{
          frame_credit: {:awaiting_ack, %AckLease{} = lease, _successor},
          rejection_state: %{
            adaptation: %{
              generation: generation,
              frame_seq: frame_seq,
              dimension: dimension,
              rejected_value: rejected_value,
              adapted_value: adapted_value,
              intent: %Intent{} = adapted
            }
          }
        } = state,
        %AckLease{generation: generation, attempt: %FrameAttempt{seq: frame_seq}}
      )
      when lease.generation == generation and lease.attempt.seq == frame_seq and
             rejected_value != adapted_value and adapted != lease.attempt.intent do
    rejected = lease.attempt.intent

    if advertised_dimension?(rejected, dimension) do
      cleared = %{state | rejection_state: RejectionState.clear(state.rejection_state)}
      {:ok, cleared, adapted}
    else
      :error
    end
  end

  def consume_adaptation(%__MODULE__{}, %AckLease{}), do: :error

  @spec clear_rejection(t()) :: t()
  def clear_rejection(%__MODULE__{} = state) do
    %{state | rejection_state: RejectionState.clear(state.rejection_state)}
  end

  @spec reconcile_windows(t(), Intent.t()) :: t()
  def reconcile_windows(%__MODULE__{} = state, %Intent{windows: windows}) do
    wanted =
      Map.new(windows, fn
        {window_id, %{content: {:buffer, buffer}}} -> {window_id, buffer}
        {window_id, _semantic_window} -> {window_id, nil}
      end)

    resident_windows =
      Enum.reduce(wanted, %{}, fn
        {window_id, buffer}, acc when is_pid(buffer) ->
          existing = Map.get(state.resident_windows, window_id)

          resident =
            case existing do
              %ResidentWindowState{buffer: ^buffer} ->
                existing

              %ResidentWindowState{} ->
                ResidentWindowState.new(window_id, buffer, :buffer_replacement)

              nil ->
                ResidentWindowState.new(window_id, buffer, :renderer_restart)
            end

          Map.put(acc, window_id, resident)

        {_window_id, _non_buffer}, acc ->
          acc
      end)

    buffers = resident_windows |> Map.values() |> MapSet.new(& &1.buffer)
    observed_buffers = ObservedBuffers.reconcile(state.observed_buffers, buffers)

    %{
      state
      | resident_windows: resident_windows,
        observed_buffers: observed_buffers
    }
  end

  @spec drop_buffer_down(t(), reference(), pid()) :: {t(), boolean()}
  def drop_buffer_down(%__MODULE__{} = state, ref, buffer)
      when is_reference(ref) and is_pid(buffer) do
    {observed_buffers, matched?} = ObservedBuffers.drop_down(state.observed_buffers, ref, buffer)

    if matched? do
      windows =
        Map.reject(state.resident_windows, fn {_id, resident} -> resident.buffer == buffer end)

      {%{state | resident_windows: windows, observed_buffers: observed_buffers}, true}
    else
      {state, false}
    end
  end

  @spec reset_frontend(t(), ResidentWindowState.hydration_reason()) :: t()
  def reset_frontend(%__MODULE__{} = state, reason \\ :reset_required) do
    residents =
      Map.new(state.resident_windows, fn {id, resident} ->
        hydrated =
          ResidentWindowState.require_hydration(
            resident,
            reason,
            resident.last_version || 0,
            resident.line_count,
            resident.change_sequence
          )

        {id, hydrated}
      end)

    %{
      state
      | caches: Caches.reset_frontend_state(state.caches),
        font_registry: FontRegistry.require_reregistration(state.font_registry),
        message_store: reset_message_cursor(state.message_store),
        resident_windows: residents
    }
  end

  defp advance_successor(state, nil), do: {:idle, state}
  defp advance_successor(state, %FrameAttempt{} = successor), do: {:schedule, state, successor}

  defp advertised_dimension?(
         %Intent{frame: %{capabilities: %Capabilities{resource_policy: policy}}},
         dimension
       ),
       do: ResourcePolicy.advertised?(policy, dimension)

  defp advertised_dimension?(%Intent{}, _dimension), do: false

  defp reset_message_cursor(%MessageStore{} = store), do: MessageStore.reset_sent_cursor(store)
  defp reset_message_cursor(nil), do: nil
end
