defmodule MingaEditor.Renderer.FrameHandler do
  @moduledoc "Frame credit, coalescing, pipeline execution, and renderer receipts."

  alias Minga.Telemetry
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.AckLease
  alias MingaEditor.Renderer.FrameAttempt
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
  defp enqueue_accepted(%State{} = state, intent, seq, pushed_at) do
    attempt = FrameAttempt.new(intent, seq, pushed_at)
    Telemetry.hop_latency(:cast_snapshot, pushed_at)

    case State.coalesce_frame(state, attempt) do
      :idle ->
        token = schedule_render()
        {:noreply, State.schedule_frame(state, attempt, token)}

      {:coalesced, coalesced, dropped} ->
        emit_coalesced(dropped, seq)
        {:noreply, coalesced}
    end
  end

  @spec dispatch(term(), State.t()) :: result()
  def dispatch({:do_render, token}, state) when is_reference(token) do
    case State.consume_render_token(state, token) do
      {:ok, render_state, attempt, retry_count} -> run(render_state, attempt, retry_count)
      :stale -> {:noreply, state}
    end
  end

  def dispatch(:do_render, state), do: {:noreply, state}

  def dispatch({:frame_status, status}, state),
    do: MingaEditor.Renderer.AckHandler.handle(state, status)

  def dispatch({:frame_ack_timeout, generation, seq}, state),
    do: MingaEditor.Renderer.AckHandler.timeout(state, generation, seq)

  def dispatch(:request_recovery, state), do: MingaEditor.Renderer.RecoveryHandler.request(state)

  def dispatch({:DOWN, ref, :process, buffer, _reason}, state) do
    {state, _matched?} = State.drop_buffer_down(state, ref, buffer)
    {:noreply, state}
  end

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

  @doc "Executes the currently scheduled asynchronous frame."
  @spec run(State.t(), FrameAttempt.t(), non_neg_integer()) :: result()
  def run(%State{} = state, %FrameAttempt{} = attempt, retry_count) do
    {prepared, input} = BufferChanges.prepare(state, attempt.intent)

    case execute_pipeline(prepared, input, attempt.intent, attempt.seq, attempt.pushed_at) do
      {:ok, committed, output} -> await_or_commit(committed, output, attempt)
      {:stale, error, retained} -> retry_stale(retained, attempt, retry_count, error)
      {:error, error, retained} -> drop_failed(retained, error, attempt.seq)
    end
  end

  @doc "Advances to the latest coalesced intent or returns the renderer to idle."
  @spec advance(State.t()) :: result()
  def advance(%State{} = state) do
    case State.advance_credit(state) do
      {:idle, idle} ->
        {:noreply, idle}

      {:schedule, advanced, %FrameAttempt{} = attempt} ->
        token = schedule_render()
        {:noreply, State.schedule_frame(advanced, attempt, token)}
    end
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
        input |> Input.with_frame_seq(seq) |> state.pipeline.()
      end)

    committed = BufferChanges.commit(state, output, intent)
    emit_frame_telemetry(output, seq, pushed_at)
    {:ok, committed, output}
  rescue
    error in [StaleBufferError] -> {:stale, error, state}
    error -> {:error, error, state}
  end

  @spec await_or_commit(State.t(), Input.t(), FrameAttempt.t()) :: result()
  defp await_or_commit(%State{require_ack?: true} = state, output, %FrameAttempt{} = attempt) do
    lease = AckLease.start(attempt, output, state.ack_timeout_ms)

    state = %{state | font_registry: output.font_registry}
    {:noreply, State.await_ack(state, lease)}
  end

  defp await_or_commit(state, output, %FrameAttempt{} = attempt) do
    state = commit_output(state, output)
    send_receipt(state.editor_pid, output, attempt.seq, attempt.intent)
    advance(state)
  end

  @spec retry_stale(State.t(), FrameAttempt.t(), non_neg_integer(), StaleBufferError.t()) ::
          result()
  defp retry_stale(%State{} = state, %FrameAttempt{}, retry_count, _error)
       when retry_count < @max_stale_retries do
    token = schedule_render()
    {:noreply, State.retry_scheduled_frame(state, token)}
  end

  defp retry_stale(state, %FrameAttempt{} = attempt, _retry_count, error) do
    Minga.Log.warning(
      :render,
      "Renderer frame #{attempt.seq} exhausted stale-buffer retries: #{Exception.message(error)}"
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

  @spec emit_coalesced(FrameAttempt.t() | nil, non_neg_integer()) :: :ok
  defp emit_coalesced(nil, _new_seq), do: :ok

  defp emit_coalesced(%FrameAttempt{seq: dropped_seq}, new_seq) do
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
