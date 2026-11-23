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
  alias MingaEditor.Renderer.StaleSearchError
  alias MingaEditor.Renderer.State
  alias MingaEditor.Renderer.Submission

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

    case execute_pipeline(prepared.pipeline, input, seq, pushed_at) do
      {:ok, output} ->
        finish_sync(prepared, output, FrameAttempt.new(intent, seq, pushed_at))

      {:stale, _error} when retry_count < @max_stale_retries ->
        do_render_sync(prepared, intent, seq, pushed_at, retry_count + 1)

      {failure, error} when failure in [:stale, :stale_search, :error] ->
        {:reply, {:error, error}, prepared}
    end
  end

  @spec finish_sync(State.t(), Input.t(), FrameAttempt.t()) ::
          {:reply, {:ok, RenderReceipt.t()}, State.t()}
  defp finish_sync(%State{require_ack?: true} = state, output, attempt) do
    scheduled = State.schedule_frame(state, attempt, make_ref())
    {:noreply, awaiting} = await_or_commit(scheduled, output, attempt)
    {:reply, {:ok, receipt(output, attempt.seq, attempt.intent)}, awaiting}
  end

  defp finish_sync(state, output, attempt) do
    {:reply, {:ok, receipt(output, attempt.seq, attempt.intent)}, commit_output(state, output)}
  end

  @doc "Executes the currently scheduled asynchronous frame."
  @spec run(State.t(), FrameAttempt.t(), non_neg_integer()) :: result()
  def run(%State{} = state, %FrameAttempt{} = attempt, retry_count) do
    {prepared, input} = BufferChanges.prepare(state, attempt.intent)

    case execute_pipeline(prepared.pipeline, input, attempt.seq, attempt.pushed_at) do
      {:ok, output} -> await_or_commit(prepared, output, attempt)
      {:stale, error} -> retry_stale(prepared, attempt, retry_count, error)
      {:stale_search, _error} -> advance(prepared)
      {:error, error} -> drop_failed(prepared, error, attempt.seq)
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

  @doc "Commits a locally completed or frontend-acknowledged frame."
  @spec commit_output(State.t(), Input.t()) :: State.t()
  def commit_output(state, output) do
    state =
      state
      |> State.commit_local_scroll_geometry(output)
      |> BufferChanges.commit(output, output.intent)

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

  @spec execute_pipeline(State.pipeline(), Input.t(), non_neg_integer(), integer()) ::
          {:ok, Input.t()}
          | {:stale, StaleBufferError.t()}
          | {:stale_search, StaleSearchError.t()}
          | {:error, Exception.t()}
  defp execute_pipeline(pipeline, input, seq, pushed_at) do
    output =
      Telemetry.span([:minga, :render, :pipeline], %{frame_seq: seq}, fn ->
        input |> Input.with_frame_seq(seq) |> pipeline.()
      end)

    emit_frame_telemetry(output, seq, pushed_at)
    {:ok, output}
  rescue
    error in [StaleBufferError] -> {:stale, error}
    error in [StaleSearchError] -> {:stale_search, error}
    error -> {:error, error}
  end

  @spec await_or_commit(State.t(), Input.t(), FrameAttempt.t()) :: result()
  defp await_or_commit(
         %State{require_ack?: true} = state,
         %Input{frame_admission: {:refused, :not_ready}},
         %FrameAttempt{} = attempt
       ) do
    # The frontend never received this frame, so no acknowledgement can follow.
    # Discard its output as a rejection would: the acknowledged bases and pending
    # font registrations stay in state. The frontend's ready handshake resets
    # the connection and renders a keyframe of the current state.
    Minga.Log.debug(:render, "Frontend not ready; discarded frame #{attempt.seq}")
    advance(state)
  end

  defp await_or_commit(%State{require_ack?: true} = state, output, %FrameAttempt{} = attempt) do
    lease = AckLease.start(attempt, output, state.ack_timeout_ms)

    # The lease owns speculative window caches. Keep the acknowledged bases
    # and consumed edits in state so a rejection can recompose from them.
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

    emit_boundary_size(:receipt_bytes, receipt, seq)
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

  @doc "Measures the transmitted request before restoring renderer-local highlight data."
  @spec observe_submission(Submission.t(), non_neg_integer()) :: :ok
  def observe_submission(submission, seq), do: emit_boundary_size(:request_bytes, submission, seq)

  @spec emit_boundary_size(:request_bytes | :receipt_bytes, term(), non_neg_integer()) :: :ok
  defp emit_boundary_size(measurement, value, seq) do
    event = [:minga, :render, :boundary]

    case :telemetry.list_handlers(event) do
      [] ->
        :ok

      _handlers ->
        Telemetry.execute(event, %{measurement => :erlang.external_size(value)}, %{frame_seq: seq})
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
