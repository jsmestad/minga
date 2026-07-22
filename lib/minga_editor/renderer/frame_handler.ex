defmodule MingaEditor.Renderer.FrameHandler do
  @moduledoc "Frame credit, coalescing, pipeline execution, and renderer receipts."

  alias Minga.Telemetry
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.StaleBufferError
  alias MingaEditor.Renderer.State

  @type result :: {:noreply, State.t()}

  @max_stale_retries 3

  @spec enqueue(State.t(), Intent.t(), non_neg_integer(), integer()) :: result()
  def enqueue(%State{} = state, %Intent{} = intent, seq, pushed_at) do
    case State.accept_intent(state, intent) do
      {:accepted, accepted} -> enqueue_accepted(accepted, intent, seq, pushed_at)
      {:blocked, blocked} -> {:noreply, blocked}
    end
  end

  @spec enqueue_accepted(State.t(), Intent.t(), non_neg_integer(), integer()) :: result()
  defp enqueue_accepted(%State{rendering?: true} = state, intent, seq, pushed_at) do
    Telemetry.hop_latency(:cast_snapshot, pushed_at)
    emit_coalesced(state.pending, seq)
    {:noreply, %{state | pending: {intent, seq, pushed_at}}}
  end

  defp enqueue_accepted(%State{rendering?: false} = state, intent, seq, pushed_at) do
    Telemetry.hop_latency(:cast_snapshot, pushed_at)
    token = schedule_render()

    {:noreply,
     %{
       state
       | rendering?: true,
         render_token: token,
         stale_retry_count: 0,
         in_flight: {intent, seq, pushed_at}
     }}
  end

  @spec dispatch(term(), State.t()) :: result()
  def dispatch({:do_render, token}, %State{render_token: token} = state)
      when is_reference(token),
      do: run(%{state | render_token: nil})

  def dispatch({:do_render, _stale_token}, state), do: {:noreply, state}
  def dispatch(:do_render, state), do: {:noreply, state}

  def dispatch({:frame_status, status}, state),
    do: MingaEditor.Renderer.AckHandler.handle(state, status)

  def dispatch({:frame_ack_timeout, generation, seq}, state),
    do: MingaEditor.Renderer.AckHandler.timeout(state, generation, seq)

  def dispatch(:request_recovery, state), do: MingaEditor.Renderer.RecoveryHandler.request(state)

  def dispatch({:DOWN, ref, :process, buffer, _reason}, state),
    do: {:noreply, BufferChanges.handle_down(state, ref, buffer)}

  def dispatch(_message, state), do: {:noreply, state}

  @doc "Runs one synchronous frame while retaining all renderer state in the server process."
  @spec render_sync(State.t(), Intent.t(), non_neg_integer(), integer()) ::
          {:reply, {:ok, RenderReceipt.t()} | {:error, Exception.t()}, State.t()}
  def render_sync(%State{} = state, %Intent{} = intent, seq, pushed_at),
    do: do_render_sync(state, intent, seq, pushed_at, 0)

  @spec do_render_sync(State.t(), Intent.t(), non_neg_integer(), integer(), non_neg_integer()) ::
          {:reply, {:ok, RenderReceipt.t()} | {:error, Exception.t()}, State.t()}
  defp do_render_sync(state, intent, seq, pushed_at, retry_count) do
    {prepared, input} = BufferChanges.prepare(state, intent)

    case execute_pipeline(prepared, input, intent, seq, pushed_at) do
      {:ok, committed, output} ->
        committed = commit_output(committed, output)
        receipt = receipt(output, seq, intent)
        {:reply, {:ok, receipt}, committed}

      {:stale, _error, retained} when retry_count < @max_stale_retries ->
        do_render_sync(retained, intent, seq, pushed_at, retry_count + 1)

      {:stale, error, retained} ->
        {:reply, {:error, error}, retained}

      {:error, error, retained} ->
        {:reply, {:error, error}, retained}
    end
  end

  @doc "Executes the currently in-flight asynchronous frame."
  @spec run(State.t()) :: result()

  def run(%State{in_flight: {%Intent{} = intent, seq, pushed_at}} = state) do
    {prepared, input} = BufferChanges.prepare(state, intent)

    case execute_pipeline(prepared, input, intent, seq, pushed_at) do
      {:ok, committed, output} -> await_or_commit(committed, output, intent, seq, pushed_at)
      {:stale, error, retained} -> retry_stale(retained, intent, seq, pushed_at, error)
      {:error, error, retained} -> drop_failed(retained, error, seq)
    end
  end

  @doc "Advances to the latest coalesced intent or returns the renderer to idle."
  @spec advance(State.t()) :: result()
  def advance(%State{pending: nil} = state),
    do:
      {:noreply,
       %{
         state
         | rendering?: false,
           render_token: nil,
           stale_retry_count: 0,
           in_flight: nil
       }}

  def advance(%State{pending: {intent, seq, pushed_at}} = state) do
    token = schedule_render()

    {:noreply,
     %{
       state
       | render_token: token,
         stale_retry_count: 0,
         in_flight: {intent, seq, pushed_at},
         pending: nil
     }}
  end

  @doc "Commits pipeline-global renderer state after composition or acknowledgement."
  @spec commit_output(State.t(), Input.t()) :: State.t()
  def commit_output(state, output) do
    %{
      state
      | font_registry: output.font_registry,
        caches: output.caches,
        message_store: output.message_store
    }
  end

  @doc "Builds and optionally sends the focused receipt."
  @spec send_receipt(State.editor_ref(), Input.t(), non_neg_integer(), Intent.t()) :: :ok
  def send_receipt(nil, _output, seq, _intent) do
    Minga.Log.warning(:render, "Renderer frame #{seq}: no editor_pid, receipt dropped")
    :ok
  end

  def send_receipt(editor_pid, output, seq, intent) when is_pid(editor_pid) do
    receipt = receipt(output, seq, intent)
    send(editor_pid, {:render_done, receipt})
    :ok
  end

  def send_receipt(editor_name, output, seq, intent) when is_atom(editor_name) do
    case Process.whereis(editor_name) do
      nil ->
        Minga.Log.warning(
          :render,
          "Renderer frame #{seq}: editor #{inspect(editor_name)} not registered, receipt dropped"
        )

        :ok

      editor_pid ->
        send_receipt(editor_pid, output, seq, intent)
    end
  end

  @spec execute_pipeline(State.t(), Input.t(), Intent.t(), non_neg_integer(), integer()) ::
          {:ok, State.t(), Input.t()}
          | {:stale, StaleBufferError.t(), State.t()}
          | {:error, Exception.t(), State.t()}
  defp execute_pipeline(state, input, intent, seq, pushed_at) do
    output =
      Telemetry.span([:minga, :render, :pipeline], %{frame_seq: seq}, fn ->
        input |> Map.put(:frame_seq, seq) |> state.pipeline.()
      end)

    committed = BufferChanges.commit(state, output, intent)
    emit_frame_telemetry(output, seq, pushed_at)
    {:ok, committed, output}
  rescue
    error in [StaleBufferError] -> {:stale, error, state}
    error -> {:error, error, state}
  end

  @spec await_or_commit(State.t(), Input.t(), Intent.t(), non_neg_integer(), integer()) ::
          result()
  defp await_or_commit(%State{require_ack?: true} = state, output, intent, seq, pushed_at) do
    generation = output.caches.recovery_generation

    timer_ref =
      Process.send_after(self(), {:frame_ack_timeout, generation, seq}, state.ack_timeout_ms)

    lease = %{
      generation: generation,
      seq: seq,
      timer_ref: timer_ref,
      output: output,
      intent: intent,
      pushed_at: pushed_at
    }

    {:noreply,
     %{state | font_registry: output.font_registry, in_flight: nil, awaiting_ack: lease}}
  end

  defp await_or_commit(state, output, intent, seq, _pushed_at) do
    state = commit_output(state, output)
    send_receipt(state.editor_pid, output, seq, intent)
    advance(state)
  end

  @spec retry_stale(
          State.t(),
          Intent.t(),
          non_neg_integer(),
          integer(),
          StaleBufferError.t()
        ) :: result()
  defp retry_stale(
         %State{stale_retry_count: retry_count} = state,
         intent,
         seq,
         pushed_at,
         _error
       )
       when retry_count < @max_stale_retries do
    token = schedule_render()

    {:noreply,
     %{
       state
       | render_token: token,
         stale_retry_count: retry_count + 1,
         in_flight: {intent, seq, pushed_at}
     }}
  end

  defp retry_stale(state, _intent, seq, _pushed_at, error) do
    Minga.Log.warning(
      :render,
      "Renderer frame #{seq} exhausted stale-buffer retries: #{Exception.message(error)}"
    )

    advance(state)
  end

  @spec drop_failed(State.t(), Exception.t(), non_neg_integer()) :: result()
  defp drop_failed(state, error, seq) do
    Minga.Log.warning(:render, "Renderer frame #{seq} dropped: #{Exception.message(error)}")
    advance(state)
  end

  @spec receipt(Input.t(), non_neg_integer(), Intent.t()) :: RenderReceipt.t()
  defp receipt(output, seq, intent) do
    receipt = RenderReceipt.from_output(output, seq, monotonic_now(), intent.revision)

    emit_boundary_sizes(intent, receipt)
    receipt
  end

  @spec emit_coalesced(State.frame_work() | nil, non_neg_integer()) :: :ok
  defp emit_coalesced(nil, _new_seq), do: :ok

  defp emit_coalesced({_intent, dropped_seq, _pushed_at}, new_seq) do
    Telemetry.execute([:minga, :render, :coalesced], %{count: 1}, %{
      dropped_seq: dropped_seq,
      new_seq: new_seq
    })
  end

  @spec emit_frame_telemetry(Input.t(), non_neg_integer(), integer()) :: :ok
  defp emit_frame_telemetry(output, seq, pushed_at) do
    Telemetry.execute(
      [:minga, :render, :frame_latency],
      %{microseconds: monotonic_now() - pushed_at},
      %{frame_seq: seq}
    )

    Telemetry.execute(
      [:minga, :render, :work],
      %{rows_composed: output.caches.frame_rows_rasterized},
      %{frame_seq: seq, path: output.caches.frame_render_path}
    )
  end

  @spec emit_boundary_sizes(Intent.t(), RenderReceipt.t()) :: :ok
  defp emit_boundary_sizes(intent, receipt) do
    event = [:minga, :render, :boundary]

    case :telemetry.list_handlers(event) do
      [] ->
        :ok

      _handlers ->
        Telemetry.execute(
          event,
          %{
            request_bytes: :erlang.external_size(intent),
            receipt_bytes: :erlang.external_size(receipt)
          },
          %{}
        )
    end
  end

  @spec schedule_render() :: reference()
  defp schedule_render do
    token = make_ref()
    send(self(), {:do_render, token})
    token
  end

  @spec monotonic_now() :: integer()
  defp monotonic_now, do: System.monotonic_time(:microsecond)
end
