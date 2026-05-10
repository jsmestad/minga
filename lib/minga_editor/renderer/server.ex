defmodule MingaEditor.Renderer.Server do
  @moduledoc """
  Standalone renderer GenServer. Owns the render pipeline so a slow
  frame doesn't block input dispatch in the Editor process.

  ## Lifecycle

  Started by `MingaEditor.Supervisor` for all non-headless backends.
  The headless backend renders synchronously in-process for test
  determinism; this server is not in the supervision tree in that case.

  ## Snapshot mechanics

  The Editor pushes `RenderPipeline.Input` snapshots via
  `cast_snapshot/3`. The Renderer holds an in-flight snapshot and a
  pending one. When a snapshot arrives while a render is in progress,
  the previous pending snapshot is dropped (most-recent-wins
  coalescing) and a `[:minga, :render, :coalesced]` telemetry event
  fires. After each render emit completes, the Renderer pulls any
  pending snapshot and starts the next frame; otherwise it goes idle.

  ## Click-region writeback

  The render pipeline computes `modeline_click_regions` and
  `tab_bar_click_regions` as part of chrome rendering. These need to
  flow back to the Editor so subsequent mouse events can resolve
  click positions. The Renderer casts
  `{:render_done, frame_seq, %{caches: c, layout: l, focus_tree: ft, click_regions: cr}}`
  back to the Editor after every emit; the Editor merges into its
  state via `apply_renderer_writeback/2`.

  ## Telemetry

  - `[:minga, :render, :pipeline]` span around `RenderPipeline.run/1`.
  - `[:minga, :render, :coalesced]` event when a pending snapshot is dropped.
  - `[:minga, :render, :frame_latency]` measurement (push timestamp → emit complete).

  ## Determinism in tests

  EditorCase tests use the headless backend, which renders
  synchronously in-process. This server is not started in the test
  supervision tree.
  """

  use GenServer

  alias Minga.Telemetry
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Input

  @typedoc "Click-region writeback payload sent to the Editor after each frame."
  @type writeback :: %{
          required(:caches) => MingaEditor.Renderer.Caches.t(),
          required(:layout) => MingaEditor.Layout.t() | nil,
          required(:focus_tree) => MingaEditor.FocusTree.t() | nil,
          required(:shell_state) => term(),
          required(:windows) => term(),
          required(:frame_seq) => non_neg_integer()
        }

  @typedoc "Renderer server state."
  @type t :: %__MODULE__{
          editor_pid: pid() | nil,
          rendering?: boolean(),
          pending: {Input.t(), non_neg_integer(), integer()} | nil,
          in_flight: {Input.t(), non_neg_integer(), integer()} | nil
        }

  defstruct editor_pid: nil,
            rendering?: false,
            pending: nil,
            in_flight: nil

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

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    editor_pid = Keyword.get(opts, :editor_pid, MingaEditor)
    {:ok, %__MODULE__{editor_pid: editor_pid}}
  end

  @impl true
  @spec handle_cast({:render, Input.t(), non_neg_integer(), integer()}, t()) :: {:noreply, t()}
  def handle_cast({:render, snap, seq, pushed_at}, %__MODULE__{rendering?: true} = state) do
    # In-flight render is still going. Drop the previous pending and replace
    # with this snapshot. Most-recent-wins.
    if state.pending do
      Telemetry.execute([:minga, :render, :coalesced], %{count: 1}, %{
        dropped_seq: elem(state.pending, 1),
        new_seq: seq
      })
    end

    {:noreply, %{state | pending: {snap, seq, pushed_at}}}
  end

  def handle_cast({:render, snap, seq, pushed_at}, %__MODULE__{rendering?: false} = state) do
    send(self(), :do_render)
    {:noreply, %{state | rendering?: true, in_flight: {snap, seq, pushed_at}}}
  end

  @impl true
  @spec handle_info(:do_render, t()) :: {:noreply, t()}
  def handle_info(:do_render, %__MODULE__{in_flight: {snap, seq, pushed_at}} = state) do
    output =
      Telemetry.span(
        [:minga, :render, :pipeline],
        %{frame_seq: seq},
        fn -> RenderPipeline.run(snap) end
      )

    emit_complete_at = monotonic_now()

    Telemetry.execute(
      [:minga, :render, :frame_latency],
      %{microseconds: emit_complete_at - pushed_at},
      %{frame_seq: seq}
    )

    send_writeback(state.editor_pid, output, seq)
    advance_pending(state)
  rescue
    e ->
      Minga.Log.warning(:render, "Renderer frame #{seq} dropped: #{Exception.message(e)}")
      advance_pending(state)
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec send_writeback(pid() | atom() | nil, map(), non_neg_integer()) :: :ok
  defp send_writeback(editor_pid, output, seq) when is_pid(editor_pid) or is_atom(editor_pid) do
    writeback = %{
      caches: output.caches,
      layout: output.layout,
      focus_tree: output.focus_tree,
      shell_state: output.shell_state,
      windows: output.workspace.windows,
      frame_seq: seq
    }

    send(editor_pid, {:render_done, writeback})
    :ok
  end

  defp send_writeback(_editor_pid, _output, seq) do
    Minga.Log.warning(:render, "Renderer frame #{seq}: no editor_pid, writeback dropped")
    :ok
  end

  @spec advance_pending(t()) :: {:noreply, t()}
  defp advance_pending(state) do
    case state.pending do
      nil ->
        {:noreply, %{state | rendering?: false, in_flight: nil}}

      {next_snap, next_seq, next_pushed_at} ->
        send(self(), :do_render)
        {:noreply, %{state | in_flight: {next_snap, next_seq, next_pushed_at}, pending: nil}}
    end
  end

  @spec monotonic_now() :: integer()
  defp monotonic_now, do: System.monotonic_time(:microsecond)
end
