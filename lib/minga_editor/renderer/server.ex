defmodule MingaEditor.Renderer.Server do
  @moduledoc """
  Standalone renderer GenServer. Owns the render pipeline and font registry
  so a slow frame doesn't block input dispatch in the Editor process.

  ## Lifecycle

  Started by `MingaEditor.Supervisor` for all non-headless backends.
  The headless backend renders synchronously in-process for test
  determinism; this server is not in the supervision tree in that case.

  ## Snapshot mechanics

  The Editor pushes `RenderPipeline.Input` snapshots via
  `cast_snapshot/3`. The Renderer holds an in-flight snapshot, a
  pending one, and the latest frontend cache state it emitted. When a
  snapshot arrives while a render is in progress, the previous pending
  snapshot is dropped (most-recent-wins coalescing) and a
  `[:minga, :render, :coalesced]` telemetry event fires. Each snapshot
  is normalized against the renderer-owned cache state before it renders.
  After each acknowledged render completes, the Renderer stores the committed
  cache state and threads it into any pending snapshot before starting the next
  frame; otherwise it goes idle. The Renderer is the sole production frame
  emitter, keeping delta bases aligned with the frontend's acknowledged state
  even when the Editor has not yet processed the prior render writeback.

  ## Click-region writeback

  The render pipeline computes `modeline_click_regions` and
  `tab_bar_click_regions` as part of chrome rendering. These need to
  flow back to the Editor so subsequent mouse events can resolve
  click positions. The Renderer sends `{:render_done, writeback}`
  back to the Editor after every emit; the Editor merges renderer-owned
  fields from that payload via `apply_renderer_writeback/2`.

  ## Telemetry

  - `[:minga, :render, :pipeline]` span around `RenderPipeline.run/1`.
  - `[:minga, :render, :coalesced]` event when a pending snapshot is dropped.
  - `[:minga, :render, :frame_latency]` measurement (push timestamp → emit complete).
  - `[:minga, :render, :hop_latency]` (`hop: :cast_snapshot`) measures the
    Editor → Renderer.Server scheduling delay; (`hop: :render_done`) measures
    the Renderer.Server → Editor writeback scheduling delay.

  ## Determinism in tests

  EditorCase tests use the headless backend, which renders
  synchronously in-process. This server is not started in the test
  supervision tree.
  """

  use GenServer

  alias Minga.RenderModel.Window.LineIdentity
  alias Minga.Telemetry
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.Window

  @typedoc "Render pipeline output after a frame has run."
  @type render_output :: Input.t()

  @typedoc "Injected render pipeline function."
  @type pipeline :: (Input.t() -> render_output())

  @typedoc "Click-region writeback payload sent to the Editor after each frame."
  @type writeback :: %{
          required(:caches) => MingaEditor.Renderer.Caches.t(),
          required(:layout) => MingaEditor.Layout.t() | nil,
          required(:focus_tree) => MingaEditor.FocusTree.t() | nil,
          required(:shell_id) => atom(),
          required(:shell_identity) => MingaEditor.Shell.Identity.t() | nil,
          required(:shell_state) => term(),
          required(:windows) => term(),
          required(:message_store) => MingaEditor.UI.Panel.MessageStore.t(),
          required(:frame_seq) => non_neg_integer(),
          required(:keyframe?) => boolean(),
          required(:render_sent_at) => integer()
        }

  @typedoc "Editor process reference used for renderer writebacks."
  @type editor_ref :: pid() | atom() | nil

  @typedoc "Generation-scoped lease for one frame awaiting frontend acknowledgement."
  @type ack_lease :: %{
          required(:generation) => non_neg_integer(),
          required(:seq) => non_neg_integer(),
          required(:timer_ref) => reference(),
          required(:output) => render_output(),
          required(:snapshot) => Input.t(),
          required(:pushed_at) => integer()
        }

  @typedoc "Renderer server state."
  @type t :: %__MODULE__{
          editor_pid: editor_ref(),
          rendering?: boolean(),
          pending: {Input.t(), non_neg_integer(), integer()} | nil,
          in_flight: {Input.t(), non_neg_integer(), integer()} | nil,
          awaiting_ack: ack_lease() | nil,
          ack_timeout_ms: pos_integer(),
          font_registry: FontRegistry.t(),
          caches: Caches.t(),
          message_store: MessageStore.t() | nil,
          lineages: %{
            optional({Window.id(), pid()}) => {LineIdentity.t(), non_neg_integer()}
          },
          row_slot_allocators: %{
            optional({Window.id(), pid()}) => Minga.RenderModel.Window.RowSlotAllocator.t()
          },
          pipeline: pipeline(),
          require_ack?: boolean()
        }

  defstruct editor_pid: nil,
            rendering?: false,
            pending: nil,
            in_flight: nil,
            awaiting_ack: nil,
            ack_timeout_ms: 2_000,
            font_registry: FontRegistry.new(),
            caches: Caches.new(),
            message_store: nil,
            lineages: %{},
            row_slot_allocators: %{},
            pipeline: &RenderPipeline.run/1,
            require_ack?: true

  # ── API ────────────────────────────────────────────────────────────────────

  @doc """
  Starts the Renderer server. The `:editor_pid` option names the Editor
  process to send `{:render_done, ...}` writebacks to; defaults to
  `MingaEditor` (the registered name of the Editor GenServer).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Pushes a render snapshot. Returns immediately; the actual emit
  happens asynchronously. If a previous snapshot is still rendering,
  this snapshot replaces any prior pending one.
  """
  @spec cast_snapshot(GenServer.server(), Input.t(), non_neg_integer()) :: :ok
  def cast_snapshot(server \\ __MODULE__, %Input{} = snapshot, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0 do
    GenServer.cast(server, {:render, snapshot, frame_seq, monotonic_now()})
  end

  @doc "Returns true while rendering or waiting for the frontend's one frame credit."
  @spec rendering?(GenServer.server()) :: boolean()
  def rendering?(server \\ __MODULE__) do
    GenServer.call(server, :rendering?)
  end

  @doc "Returns the current recovery generation and acknowledged frame for diagnostics."
  @spec acknowledgement_state(GenServer.server()) :: {non_neg_integer(), non_neg_integer()}
  def acknowledgement_state(server \\ __MODULE__) do
    GenServer.call(server, :acknowledgement_state)
  end

  @doc "Returns one frame credit after a typed frontend status."
  @spec frame_status(GenServer.server(), MingaEditor.Frontend.Protocol.input_event()) :: :ok
  def frame_status(server \\ __MODULE__, status) do
    send(server, {:frame_status, status})
    :ok
  end

  @doc "Starts a fresh recovery generation for automatic or manual retry."
  @spec request_recovery(GenServer.server()) :: :ok
  def request_recovery(server \\ __MODULE__) do
    send(server, :request_recovery)
    :ok
  end

  @doc """
  Replaces all work tied to the previous frontend connection with the latest
  editor intent. The replacement starts at base zero in a fresh recovery
  generation and owns the connection's single frame credit.
  """
  @spec reset_connection(GenServer.server(), Input.t(), non_neg_integer()) :: :ok
  def reset_connection(server \\ __MODULE__, %Input{} = snapshot, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0 do
    GenServer.call(server, {:reset_connection, snapshot, frame_seq, monotonic_now()})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    editor_pid = Keyword.get(opts, :editor_pid, MingaEditor)
    pipeline = Keyword.get(opts, :pipeline, &RenderPipeline.run/1)
    require_ack? = Keyword.get(opts, :require_ack?, not Keyword.has_key?(opts, :pipeline))
    ack_timeout_ms = Keyword.get(opts, :ack_timeout_ms, 2_000)

    {:ok,
     %__MODULE__{
       editor_pid: editor_pid,
       pipeline: pipeline,
       require_ack?: require_ack?,
       ack_timeout_ms: ack_timeout_ms
     }}
  end

  @impl true
  def handle_call(:rendering?, _from, state) do
    {:reply, state.rendering?, state}
  end

  def handle_call(:acknowledgement_state, _from, state) do
    {:reply, {state.caches.recovery_generation, state.caches.last_acknowledged_frame_seq}, state}
  end

  def handle_call({:reset_connection, snap, seq, pushed_at}, _from, state) do
    cancel_ack_timer(state.awaiting_ack)
    caches = Caches.reset_frontend_state(state.caches)

    # The Editor snapshot has already reset all frontend-retained cursors for
    # this connection (including MessageStore). Do not merge state from the
    # replaced frontend back into it.
    retry = %{snap | caches: caches, force_keyframe?: true}

    # Every queued or awaiting frame belongs to the replaced connection. Abandon
    # that credit and render only the latest Editor snapshot for the new one.
    send(self(), :do_render)

    state = %{
      state
      | rendering?: true,
        pending: nil,
        in_flight: {retry, seq, pushed_at},
        awaiting_ack: nil,
        caches: caches
    }

    {:reply, :ok, state}
  end

  @impl true
  @spec handle_cast({:render, Input.t(), non_neg_integer(), integer()}, t()) :: {:noreply, t()}
  def handle_cast({:render, snap, seq, pushed_at}, %__MODULE__{rendering?: true} = state) do
    Telemetry.hop_latency(:cast_snapshot, pushed_at)

    # In-flight render is still going. Drop the previous pending and replace
    # with this snapshot. Most-recent-wins.
    if state.pending do
      Telemetry.execute([:minga, :render, :coalesced], %{count: 1}, %{
        dropped_seq: elem(state.pending, 1),
        new_seq: seq
      })
    end

    snap = use_latest_renderer_state(snap, state.caches, state.message_store)
    {:noreply, %{state | pending: {snap, seq, pushed_at}}}
  end

  def handle_cast({:render, snap, seq, pushed_at}, %__MODULE__{rendering?: false} = state) do
    Telemetry.hop_latency(:cast_snapshot, pushed_at)
    send(self(), :do_render)
    snap = use_latest_renderer_state(snap, state.caches, state.message_store)
    {:noreply, %{state | rendering?: true, in_flight: {snap, seq, pushed_at}}}
  end

  @impl true
  @spec handle_info(:do_render, t()) :: {:noreply, t()}
  def handle_info(:do_render, %__MODULE__{in_flight: {snap, seq, pushed_at}} = state) do
    snap = overlay_lineages(snap, state.lineages, state.row_slot_allocators)

    output =
      Telemetry.span(
        [:minga, :render, :pipeline],
        %{frame_seq: seq},
        fn ->
          snap
          |> Input.with_font_registry(state.font_registry)
          |> Map.put(:frame_seq, seq)
          |> state.pipeline.()
        end
      )

    emit_complete_at = monotonic_now()

    Telemetry.execute(
      [:minga, :render, :frame_latency],
      %{microseconds: emit_complete_at - pushed_at},
      %{frame_seq: seq}
    )

    # Lineage follows successful BEAM pipeline application, not frontend cache
    # acknowledgement. Rejection/ref-miss retries therefore rebase from it, while
    # the rescue path below deliberately leaves it unchanged.
    {lineages, row_slot_allocators} =
      commit_lineages(state.lineages, state.row_slot_allocators, output)

    # Port write is not proof of frontend commit. Keep the prepared output private
    # until the matching generation/sequence acknowledgement returns the credit.
    if state.require_ack? do
      generation = output.caches.recovery_generation

      timer_ref =
        Process.send_after(self(), {:frame_ack_timeout, generation, seq}, state.ack_timeout_ms)

      lease = %{
        generation: generation,
        seq: seq,
        timer_ref: timer_ref,
        output: output,
        snapshot: snap,
        pushed_at: pushed_at
      }

      state = %{
        state
        | font_registry: output.font_registry,
          lineages: lineages,
          row_slot_allocators: row_slot_allocators,
          in_flight: nil,
          awaiting_ack: lease
      }

      {:noreply, state}
    else
      # Injected pure pipelines are used by legacy server unit tests and have no
      # frontend transport. Their return is the commit boundary.
      state = %{
        state
        | font_registry: output.font_registry,
          caches: output.caches,
          message_store: output.message_store,
          lineages: lineages,
          row_slot_allocators: row_slot_allocators
      }

      send_writeback(state.editor_pid, output, seq)
      advance_pending(state, output.caches, output.message_store)
    end
  rescue
    e ->
      trace = Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 500)

      Minga.Log.warning(
        :render,
        "Renderer frame #{seq} dropped: #{Exception.message(e)}\n#{trace}"
      )

      advance_pending(state, state.caches, state.message_store)
  end

  def handle_info(
        {:frame_status, {:frame_applied, generation, seq}},
        %__MODULE__{awaiting_ack: %{generation: generation, seq: seq, output: output} = lease} =
          state
      ) do
    cancel_ack_timer(lease)
    acknowledged = Caches.acknowledge_frame(output.caches, seq, generation)

    output = %{output | caches: acknowledged}
    send_writeback(state.editor_pid, output, seq)

    state = %{
      state
      | caches: acknowledged,
        message_store: output.message_store,
        awaiting_ack: nil
    }

    advance_pending(state, acknowledged, output.message_store)
  end

  def handle_info(
        {:frame_status, {:frame_rejected, generation, seq, last_applied, reason}},
        %__MODULE__{
          awaiting_ack: %{
            generation: generation,
            seq: seq,
            snapshot: snap,
            pushed_at: pushed_at
          }
        } = state
      )
      when last_applied == state.caches.last_acknowledged_frame_seq do
    Minga.Log.warning(:render, "Frontend rejected frame #{seq}: #{reason}")
    recover_transaction(state, snap, seq, pushed_at)
  end

  def handle_info(
        {:frame_status, {:window_ref_miss, generation, seq, last_applied, window_id}},
        %__MODULE__{
          awaiting_ack: %{
            generation: generation,
            seq: seq,
            snapshot: snap,
            pushed_at: pushed_at
          }
        } = state
      )
      when last_applied == state.caches.last_acknowledged_frame_seq do
    Minga.Log.warning(:render, "Frontend missed window #{window_id} in frame #{seq}")
    recover_window(state, snap, seq, pushed_at, window_id)
  end

  # Stale, duplicate, out-of-order, wrong-generation, and unsolicited statuses
  # are intentionally side-effect free: they cannot return credit or retrigger recovery.
  def handle_info({:frame_status, _status}, state), do: {:noreply, state}

  def handle_info(
        {:frame_ack_timeout, generation, seq},
        %__MODULE__{
          awaiting_ack: %{
            generation: generation,
            seq: seq,
            snapshot: snap,
            pushed_at: pushed_at
          }
        } = state
      ) do
    Minga.Log.warning(:render, "Frontend acknowledgement timed out for frame #{seq}")
    recover_transaction(state, snap, seq, pushed_at)
  end

  def handle_info({:frame_ack_timeout, _generation, _seq}, state), do: {:noreply, state}

  def handle_info(
        :request_recovery,
        %__MODULE__{awaiting_ack: %{snapshot: snap, seq: seq, pushed_at: pushed_at}} = state
      ) do
    recover_transaction(state, snap, seq, pushed_at)
  end

  def handle_info(:request_recovery, %__MODULE__{pending: {snap, seq, pushed_at}} = state) do
    recover_transaction(state, snap, seq, pushed_at)
  end

  def handle_info(:request_recovery, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec send_writeback(editor_ref(), render_output(), non_neg_integer()) :: :ok
  defp send_writeback(nil, _output, seq) do
    Minga.Log.warning(:render, "Renderer frame #{seq}: no editor_pid, writeback dropped")
    :ok
  end

  defp send_writeback(editor_pid, output, seq) when is_pid(editor_pid) do
    send(editor_pid, {:render_done, writeback_from_output(output, seq)})
    :ok
  end

  defp send_writeback(editor_name, output, seq) when is_atom(editor_name) do
    case Process.whereis(editor_name) do
      nil ->
        Minga.Log.warning(
          :render,
          "Renderer frame #{seq}: editor #{inspect(editor_name)} not registered, writeback dropped"
        )

        :ok

      editor_pid ->
        send_writeback(editor_pid, output, seq)
    end
  end

  @spec writeback_from_output(render_output(), non_neg_integer()) :: writeback()
  defp writeback_from_output(output, seq) do
    %{
      caches: output.caches,
      layout: output.layout,
      focus_tree: output.focus_tree,
      shell_id: output.shell_id,
      shell_identity: output.shell_identity,
      shell_state: output.shell_state,
      windows: output.workspace.windows,
      message_store: output.message_store,
      frame_seq: seq,
      # Whether the frame this render emitted carried the keyframe. The Editor clears
      # keyframe_pending? only on a writeback that actually honored the request, so an
      # in-flight delta render can't swallow a pending keyframe (#2219).
      keyframe?: output.caches.last_frame_keyframe?,
      # Stamped at writeback construction (immediately before send) so the
      # Editor can measure the Renderer.Server → Editor scheduling delay.
      render_sent_at: monotonic_now()
    }
  end

  @spec advance_pending(t(), Caches.t(), MessageStore.t() | nil) :: {:noreply, t()}
  defp advance_pending(state, latest_caches, latest_message_store) do
    case state.pending do
      nil ->
        {:noreply, %{state | rendering?: false, in_flight: nil}}

      {next_snap, next_seq, next_pushed_at} ->
        send(self(), :do_render)
        next_snap = use_latest_renderer_state(next_snap, latest_caches, latest_message_store)
        {:noreply, %{state | in_flight: {next_snap, next_seq, next_pushed_at}, pending: nil}}
    end
  end

  @spec recover_transaction(t(), Input.t(), non_neg_integer(), integer()) :: {:noreply, t()}
  defp recover_transaction(state, rejected_snap, rejected_seq, rejected_pushed_at) do
    cancel_ack_timer(state.awaiting_ack)

    {latest_snap, latest_seq, latest_pushed_at} =
      latest_intent(state.pending, rejected_snap, rejected_seq, rejected_pushed_at)

    caches = Caches.reset_frontend_state(state.caches)
    retry = %{latest_snap | caches: caches, force_keyframe?: true}

    state = %{
      state
      | caches: caches,
        awaiting_ack: nil,
        pending: {retry, latest_seq, latest_pushed_at}
    }

    advance_pending(state, caches, state.message_store)
  end

  @spec recover_window(t(), Input.t(), non_neg_integer(), integer(), non_neg_integer()) ::
          {:noreply, t()}
  defp recover_window(state, rejected_snap, rejected_seq, rejected_pushed_at, window_id) do
    cancel_ack_timer(state.awaiting_ack)

    {latest_snap, latest_seq, latest_pushed_at} =
      latest_intent(state.pending, rejected_snap, rejected_seq, rejected_pushed_at)

    latest_snap = %{latest_snap | caches: state.caches}

    case Input.invalidate_window(latest_snap, window_id) do
      {:ok, retry} ->
        state = %{
          state
          | awaiting_ack: nil,
            pending: {retry, latest_seq, latest_pushed_at}
        }

        advance_pending(state, state.caches, state.message_store)

      :error ->
        recover_transaction(state, latest_snap, latest_seq, latest_pushed_at)
    end
  end

  @spec cancel_ack_timer(ack_lease() | nil) :: :ok
  defp cancel_ack_timer(nil), do: :ok

  defp cancel_ack_timer(%{timer_ref: timer_ref}) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  @spec latest_intent(
          {Input.t(), non_neg_integer(), integer()} | nil,
          Input.t(),
          non_neg_integer(),
          integer()
        ) :: {Input.t(), non_neg_integer(), integer()}
  defp latest_intent(
         {%Input{} = snap, seq, pushed_at},
         _fallback,
         rejected_seq,
         _fallback_pushed_at
       )
       when seq > rejected_seq,
       do: {snap, seq, pushed_at}

  defp latest_intent(_pending, %Input{} = fallback, rejected_seq, fallback_pushed_at) do
    unique_seq = System.unique_integer([:positive, :monotonic])
    {fallback, max(unique_seq, rejected_seq + 1), fallback_pushed_at}
  end

  @spec use_latest_renderer_state(Input.t(), Caches.t(), MessageStore.t() | nil) :: Input.t()
  defp use_latest_renderer_state(%Input{} = snap, %Caches{} = latest_caches, latest_message_store) do
    snap
    |> use_latest_caches(latest_caches)
    |> use_latest_message_store(latest_message_store)
  end

  @spec use_latest_caches(Input.t(), Caches.t()) :: Input.t()
  defp use_latest_caches(
         %Input{caches: %Caches{recovery_generation: snap_generation}} = snap,
         %Caches{recovery_generation: latest_generation}
       )
       when snap_generation > latest_generation do
    snap
  end

  defp use_latest_caches(
         %Input{caches: %Caches{last_emitted_frame_seq: snap_seq}} = snap,
         %Caches{last_emitted_frame_seq: latest_seq}
       )
       when snap_seq > latest_seq do
    snap
  end

  defp use_latest_caches(%Input{} = snap, %Caches{} = latest_caches) do
    %{snap | caches: latest_caches}
  end

  @spec use_latest_message_store(Input.t(), MessageStore.t() | nil) :: Input.t()
  defp use_latest_message_store(%Input{} = snap, nil), do: snap

  defp use_latest_message_store(
         %Input{message_store: %MessageStore{} = store} = snap,
         %MessageStore{} = latest
       ) do
    %{snap | message_store: MessageStore.merge_sent_cursor(store, latest)}
  end

  @typep lineage_map :: %{
           optional({Window.id(), pid()}) => {LineIdentity.t(), non_neg_integer()}
         }

  @typep row_slot_allocator_map :: %{
           optional({Window.id(), pid()}) => Minga.RenderModel.Window.RowSlotAllocator.t()
         }

  @spec overlay_lineages(Input.t(), lineage_map(), row_slot_allocator_map()) :: Input.t()
  defp overlay_lineages(input, lineages, row_slot_allocators) do
    Enum.reduce(lineages, input, fn {{window_id, buffer} = key, {identity, sequence}}, acc ->
      allocator = Map.fetch!(row_slot_allocators, key)
      Input.put_window_lineage(acc, window_id, buffer, identity, sequence, allocator)
    end)
  end

  @spec commit_lineages(lineage_map(), row_slot_allocator_map(), Input.t()) ::
          {lineage_map(), row_slot_allocator_map()}
  defp commit_lineages(lineages, row_slot_allocators, %Input{workspace: %{windows: windows}}) do
    Enum.reduce(windows.map, {lineages, row_slot_allocators}, fn
      {window_id, window}, accumulators ->
        commit_window_lineage(Window.line_identity(window), window_id, window, accumulators)
    end)
  end

  @spec commit_window_lineage(
          LineIdentity.t() | nil,
          Window.id(),
          Window.t(),
          {lineage_map(), row_slot_allocator_map()}
        ) :: {lineage_map(), row_slot_allocator_map()}
  defp commit_window_lineage(nil, _window_id, _window, accumulators), do: accumulators

  defp commit_window_lineage(identity, window_id, window, {lineages, allocators}) do
    key = {window_id, window.buffer}

    {
      Map.put(lineages, key, {identity, Window.applied_change_sequence(window)}),
      Map.put(allocators, key, Window.row_slot_allocator(window))
    }
  end

  @spec monotonic_now() :: integer()
  defp monotonic_now, do: System.monotonic_time(:microsecond)
end
