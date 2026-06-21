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
  After each render emit completes, the Renderer stores the emitted
  cache state and threads it into any pending snapshot before starting
  the next frame; otherwise it goes idle. If the Editor emits a direct
  bare frame boundary, that newer snapshot cache wins instead. That keeps
  delta frame bases aligned with what the frontend just received, even
  when the Editor has not yet processed the prior render writeback.

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

  alias Minga.Telemetry
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Panel.MessageStore

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

  @typedoc "Renderer server state."
  @type t :: %__MODULE__{
          editor_pid: editor_ref(),
          rendering?: boolean(),
          pending: {Input.t(), non_neg_integer(), integer()} | nil,
          in_flight: {Input.t(), non_neg_integer(), integer()} | nil,
          font_registry: FontRegistry.t(),
          caches: Caches.t(),
          message_store: MessageStore.t() | nil,
          pipeline: pipeline()
        }

  defstruct editor_pid: nil,
            rendering?: false,
            pending: nil,
            in_flight: nil,
            font_registry: FontRegistry.new(),
            caches: Caches.new(),
            message_store: nil,
            pipeline: &RenderPipeline.run/1

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

  @doc "Returns true while a render pass is in progress."
  @spec rendering?(GenServer.server()) :: boolean()
  def rendering?(server \\ __MODULE__) do
    GenServer.call(server, :rendering?)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    editor_pid = Keyword.get(opts, :editor_pid, MingaEditor)
    pipeline = Keyword.get(opts, :pipeline, &RenderPipeline.run/1)
    {:ok, %__MODULE__{editor_pid: editor_pid, pipeline: pipeline}}
  end

  @impl true
  def handle_call(:rendering?, _from, state) do
    {:reply, state.rendering?, state}
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

    state = %{
      state
      | font_registry: output.font_registry,
        caches: output.caches,
        message_store: output.message_store
    }

    send_writeback(state.editor_pid, output, seq)
    advance_pending(state, output.caches, output.message_store)
  rescue
    e ->
      trace = Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 500)

      Minga.Log.warning(
        :render,
        "Renderer frame #{seq} dropped: #{Exception.message(e)}\n#{trace}"
      )

      advance_pending(state, state.caches, state.message_store)
  end

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

  @spec use_latest_renderer_state(Input.t(), Caches.t(), MessageStore.t() | nil) :: Input.t()
  defp use_latest_renderer_state(%Input{} = snap, %Caches{} = latest_caches, latest_message_store) do
    snap
    |> use_latest_caches(latest_caches)
    |> use_latest_message_store(latest_message_store)
  end

  @spec use_latest_caches(Input.t(), Caches.t()) :: Input.t()
  defp use_latest_caches(
         %Input{caches: %Caches{last_emitted_frame_seq: 0}} = snap,
         %Caches{last_emitted_frame_seq: latest_seq}
       )
       when latest_seq > 0 do
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

  @spec monotonic_now() :: integer()
  defp monotonic_now, do: System.monotonic_time(:microsecond)
end
