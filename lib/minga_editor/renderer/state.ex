defmodule MingaEditor.Renderer.State do
  @moduledoc """
  Complete long-lived state owned by `MingaEditor.Renderer.Server`.

  Renderer caches, font registration, frontend acknowledgement state, resident
  windows, buffer monitors, and coalesced frame credit live here. Public
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
  alias MingaEditor.Renderer.ResidentWindowState
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.Window

  @type editor_ref :: pid() | atom() | nil
  @type pipeline :: (Input.t() -> Input.t())

  @type t :: %__MODULE__{
          editor_pid: editor_ref(),
          rendering?: boolean(),
          render_token: reference() | nil,
          stale_retry_count: non_neg_integer(),
          pending: FrameAttempt.t() | nil,
          in_flight: FrameAttempt.t() | nil,
          awaiting_ack: AckLease.t() | nil,
          ack_timeout_ms: pos_integer(),
          font_registry: FontRegistry.t(),
          caches: Caches.t(),
          message_store: MessageStore.t() | nil,
          resident_windows: %{optional(Window.id()) => ResidentWindowState.t()},
          buffer_monitors: %{optional(pid()) => reference()},
          buffer_versions: %{optional(pid()) => non_neg_integer()},
          pipeline: pipeline(),
          require_ack?: boolean(),
          rejection_state: RejectionState.t()
        }

  defstruct editor_pid: nil,
            rendering?: false,
            render_token: nil,
            stale_retry_count: 0,
            pending: nil,
            in_flight: nil,
            awaiting_ack: nil,
            ack_timeout_ms: 2_000,
            font_registry: FontRegistry.new(),
            caches: Caches.new(),
            message_store: nil,
            resident_windows: %{},
            buffer_monitors: %{},
            buffer_versions: %{},
            pipeline: &RenderPipeline.run/1,
            require_ack?: true,
            rejection_state: RejectionState.new()

  @doc "Constructs renderer state with injected process dependencies."
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      editor_pid: Keyword.get(opts, :editor_pid, MingaEditor),
      pipeline: Keyword.get(opts, :pipeline, &RenderPipeline.run/1),
      require_ack?: Keyword.get(opts, :require_ack?, not Keyword.has_key?(opts, :pipeline)),
      ack_timeout_ms: Keyword.get(opts, :ack_timeout_ms, 2_000)
    }
  end

  @doc "Accepts changed semantic work and blocks an identical terminally rejected intent."
  @spec accept_intent(t(), Intent.t()) :: {:accepted, t()} | {:blocked, t()}
  def accept_intent(%__MODULE__{} = state, %Intent{} = intent) do
    if RejectionState.blocks?(state.rejection_state, intent) do
      {:blocked, state}
    else
      {:accepted, %{state | rejection_state: RejectionState.clear(state.rejection_state)}}
    end
  end

  @doc "Records adapted-retry evidence only for the matching outstanding transaction."
  @spec record_adaptation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          ResourcePolicy.adaptation_descriptor(),
          Intent.t()
        ) :: {:ok, t()} | {:error, t()}
  def record_adaptation(
        %__MODULE__{
          awaiting_ack: %AckLease{
            generation: generation,
            attempt: %FrameAttempt{seq: frame_seq, intent: rejected}
          }
        } = state,
        generation,
        frame_seq,
        %{dimension: dimension} = descriptor,
        %Intent{} = adapted
      )
      when adapted != rejected do
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

  @spec queue_frame(t(), FrameAttempt.t()) :: t()
  def queue_frame(%__MODULE__{} = state, %FrameAttempt{} = work) do
    %{state | awaiting_ack: nil, pending: work}
  end

  @doc "Enters a visible terminal frontend failure while preserving acknowledged caches."
  @spec terminal_failure(t(), non_neg_integer(), atom()) :: t()
  def terminal_failure(
        %__MODULE__{
          awaiting_ack: %AckLease{
            generation: generation,
            attempt: %FrameAttempt{seq: seq, intent: intent}
          }
        } = state,
        last_good_frame_seq,
        reason
      ) do
    rejection_state =
      RejectionState.terminal(
        state.rejection_state,
        generation,
        seq,
        last_good_frame_seq,
        reason,
        intent
      )

    %{
      state
      | awaiting_ack: nil,
        pending: nil,
        in_flight: nil,
        rendering?: false,
        render_token: nil,
        stale_retry_count: 0,
        rejection_state: rejection_state
    }
  end

  @doc "Returns the currently visible terminal frontend failure, if any."
  @spec terminal_failure(t()) :: RejectionState.terminal() | nil
  def terminal_failure(%__MODULE__{} = state), do: state.rejection_state.terminal

  @doc "Consumes matching one-shot evidence and returns its concrete adapted intent."
  @spec consume_adaptation(t(), AckLease.t()) :: {:ok, t(), Intent.t()} | :error
  def consume_adaptation(
        %__MODULE__{
          awaiting_ack: %AckLease{
            generation: generation,
            attempt: %FrameAttempt{seq: frame_seq, intent: rejected}
          },
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
      when rejected_value != adapted_value and adapted != rejected do
    if advertised_dimension?(rejected, dimension) do
      cleared = %{state | rejection_state: RejectionState.clear(state.rejection_state)}
      {:ok, cleared, adapted}
    else
      :error
    end
  end

  def consume_adaptation(%__MODULE__{}, %AckLease{}), do: :error

  @doc "Clears rejection visibility after reconnect or another external state change."
  @spec clear_rejection(t()) :: t()
  def clear_rejection(%__MODULE__{} = state) do
    %{state | rejection_state: RejectionState.clear(state.rejection_state)}
  end

  @doc "Drops windows absent from the latest intent and monitors each live buffer once."
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
    {monitors, versions} = reconcile_monitors(state, buffers)

    %{
      state
      | resident_windows: resident_windows,
        buffer_monitors: monitors,
        buffer_versions: versions
    }
  end

  @doc "Drops all state for the exact monitored buffer death."
  @spec drop_buffer_down(t(), reference(), pid()) :: {t(), boolean()}
  def drop_buffer_down(%__MODULE__{} = state, ref, buffer)
      when is_reference(ref) and is_pid(buffer) do
    case Map.get(state.buffer_monitors, buffer) do
      ^ref ->
        windows =
          Map.reject(state.resident_windows, fn {_id, resident} -> resident.buffer == buffer end)

        {%{
           state
           | resident_windows: windows,
             buffer_monitors: Map.delete(state.buffer_monitors, buffer),
             buffer_versions: Map.delete(state.buffer_versions, buffer)
         }, true}

      _other ->
        {state, false}
    end
  end

  @doc "Resets frontend-retained state and re-hydrates every resident in a fresh epoch."
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

  @spec advertised_dimension?(Intent.t(), ResourcePolicy.dimension()) :: boolean()
  defp advertised_dimension?(
         %Intent{frame: %{capabilities: %Capabilities{resource_policy: policy}}},
         dimension
       ),
       do: ResourcePolicy.advertised?(policy, dimension)

  defp advertised_dimension?(%Intent{}, _dimension), do: false

  @spec reconcile_monitors(t(), MapSet.t(pid())) ::
          {%{optional(pid()) => reference()}, %{optional(pid()) => non_neg_integer()}}
  defp reconcile_monitors(state, buffers) do
    Enum.each(state.buffer_monitors, fn {buffer, ref} ->
      if not MapSet.member?(buffers, buffer), do: Process.demonitor(ref, [:flush])
    end)

    monitors =
      Map.new(buffers, fn buffer ->
        {buffer, Map.get_lazy(state.buffer_monitors, buffer, fn -> Process.monitor(buffer) end)}
      end)

    versions = Map.take(state.buffer_versions, MapSet.to_list(buffers))
    {monitors, versions}
  end

  @spec reset_message_cursor(MessageStore.t() | nil) :: MessageStore.t() | nil
  defp reset_message_cursor(%MessageStore{} = store), do: MessageStore.reset_sent_cursor(store)
  defp reset_message_cursor(nil), do: nil
end
