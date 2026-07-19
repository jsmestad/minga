defmodule MingaEditor.Agent.Ingest do
  @moduledoc """
  Coalesces high-frequency agent stream deltas before they reach the Editor.

  Agent token deltas (`:text_delta`, `:thinking_delta`, `:tool_update`) arrive
  from `MingaAgent.Session` at potentially hundreds of messages per second.
  Delivered straight into the Editor mailbox, each one runs a real buffer write
  and sits FIFO ahead of any key press queued behind it: head-of-line blocking
  that jitters keystroke latency under streaming load (epic #2220 AC 3, #2289).

  Ingest sits between the session and the Editor. It subscribes to the session
  on the Editor's behalf via `MingaAgent.Session.subscribe/4`, so deltas land in
  *its* mailbox, not the Editor's. It then forwards one
  `{:agent_stream_batch, session_pid, batch}` per coalescing window instead of
  one message per delta. Keystrokes never pass through Ingest; they gain only a
  shorter mailbox ahead of them.

  ## Debounce strategy (leading + trailing edge)

    * **Leading edge (#2289 AC 5):** the first delta after an idle period is
      forwarded *immediately* as a one-element batch, so time-to-first-token is
      unchanged. Forwarding then starts a `Process.send_after/3` tick.
    * **Trailing edge (#2289 AC 2):** deltas that arrive while the tick is
      pending accumulate in state. When the tick fires, the whole accumulation
      forwards as a single batch and the session returns to idle. N steady-state
      deltas within one window therefore produce exactly one Editor message and
      one buffer sync.

  ## Control-event ordering (#2289 AC 3)

  Control events (status change, tool start/end, error, turn end, approvals,
  anything that is not a stream delta) flush the pending batch *ahead of
  themselves, in order*, then forward the control event unchanged as a normal
  `{:agent_event, session_pid, event}`. The Editor therefore never observes a
  turn ending before that turn's trailing text.

  This is a Layer 2 process. `MingaAgent.Session` is unchanged.

  ## Link policy

  Ingest is `start_link`'d from `MingaEditor.init/1` and is intentionally linked
  to the Editor without `trap_exit` or its own supervision. It is an
  editor-integral process: it exists only to feed the Editor, holds no state the
  Editor cannot rebuild on the next subscribe, and its callbacks are total over
  arbitrary input (`route/3` classifies any non-delta term as a control event,
  `handle_info/2` ignores unknown messages, and timer/flush handling tolerates
  stale ticks). A crash here therefore means the Editor's own assumptions are
  already broken, so propagating the crash to restart both together is the
  correct outcome rather than silently losing the coalescer. This differs from
  `Renderer.Server`, which is a supervised sibling the Editor resolves by pid;
  Ingest is cheap to recreate and owned directly by the Editor on each boot.
  """

  use GenServer

  alias MingaAgent.Session

  @typedoc "Stream delta events that Ingest coalesces."
  @type delta ::
          {:text_delta, term()}
          | {:thinking_delta, term()}
          | {:tool_update, term(), term(), term()}

  @typedoc "A coalesced run of deltas for one session, in arrival order."
  @type batch :: [delta()]

  @typedoc "Per-session accumulation: pending deltas (reversed) and the tick ref."
  @type session_state :: %{pending: [delta()], timer: reference() | nil}

  @type state :: %{
          editor: pid(),
          window_ms: non_neg_integer(),
          max_batch_items: pos_integer(),
          max_batch_bytes: pos_integer(),
          sessions: %{optional(pid()) => session_state()}
        }

  # One 60Hz frame. Adds at most one window to steady-state stream visibility,
  # below perception and partly absorbed by the Editor's render coalescing.
  @default_window_ms 16

  # Batch size caps. A single coalesced flush is split into multiple bounded
  # batches so the Editor's inline apply (`route_agent_stream_batch`) never
  # receives a pathologically large batch from a big tool-output dump or
  # paste-like burst. Item count is the primary guard; byte ceiling catches
  # fewer-but-larger deltas. Both are conservative: normal streaming rarely
  # exceeds a handful of small token deltas per 16ms window.
  @max_batch_items 64
  @max_batch_bytes 32_768

  # Provider startup can delay the queued Session call. The outer Ingest call
  # gets five additional seconds so the bounded inner result can reply first.
  @session_subscribe_timeout_ms 300_000

  @telemetry_flush [:minga, :agent, :ingest_flush]

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the ingest process.

  `:editor` is the pid that batches and control events are forwarded to and
  defaults to the calling process. `:window_ms` overrides the coalescing tick
  (tests pass `0` so the tick fires on the next message turn deterministically).
  `:max_batch_items` and `:max_batch_bytes` override the batch size caps (tests
  use small values to exercise the splitting logic without generating hundreds
  of deltas).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Subscribes Ingest to `session_pid` so the session's events flow through here.

  Runs the `MingaAgent.Session.subscribe/4` call inside the Ingest process so
  Ingest (not the caller) becomes the session subscriber. Returns the result of
  the subscribe call.
  """
  @spec subscribe_session(GenServer.server(), pid(), keyword()) ::
          :ok | {:error, term()}
  def subscribe_session(server, session_pid, opts \\ []) when is_pid(session_pid) do
    GenServer.call(
      server,
      {:subscribe_session, session_pid, opts},
      @session_subscribe_timeout_ms + 5_000
    )
  end

  # ── Server callbacks ─────────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    editor = Keyword.get(opts, :editor, self())
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    max_items = Keyword.get(opts, :max_batch_items, @max_batch_items)
    max_bytes = Keyword.get(opts, :max_batch_bytes, @max_batch_bytes)

    {:ok,
     %{
       editor: editor,
       window_ms: window_ms,
       max_batch_items: max_items,
       max_batch_bytes: max_bytes,
       sessions: %{}
     }}
  end

  @impl true
  @spec handle_call({:subscribe_session, pid(), keyword()}, GenServer.from(), state()) ::
          {:reply, :ok | {:error, term()}, state()}
  def handle_call({:subscribe_session, session_pid, opts}, _from, state) do
    {:reply, do_subscribe(session_pid, opts), state}
  end

  @impl true
  @spec handle_info({:agent_event, pid(), term()}, state()) :: {:noreply, state()}
  def handle_info({:agent_event, session_pid, event}, state) do
    {:noreply, route(state, session_pid, event)}
  end

  def handle_info({:ingest_tick, session_pid}, state) do
    {:noreply, flush(state, session_pid, :tick)}
  end

  # Ingest monitors each session it subscribes to (see do_subscribe/2). When a
  # session dies we drop its per-session accumulation so a crashed session never
  # leaves a stale entry (and a stale armed timer) behind. The Editor learns of
  # the death via its own SessionManager subscription, so no forwarding is
  # needed here.
  def handle_info({:DOWN, _ref, :process, session_pid, _reason}, state) do
    {:noreply, drop_session(state, session_pid)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Routing ──────────────────────────────────────────────────────────────────

  @spec route(state(), pid(), term()) :: state()
  defp route(state, session_pid, event) do
    route(state, session_pid, event, delta?(event))
  end

  @spec route(state(), pid(), term(), boolean()) :: state()
  defp route(state, session_pid, event, true), do: accumulate(state, session_pid, event)

  defp route(state, session_pid, event, false) do
    # Control event: flush any pending deltas ahead of it (in order), then
    # forward the control event unchanged. AC 3.
    state = flush(state, session_pid, :control)
    forward_control(state, session_pid, event)
    state
  end

  @spec delta?(term()) :: boolean()
  defp delta?({:text_delta, _}), do: true
  defp delta?({:thinking_delta, _}), do: true
  defp delta?({:tool_update, _, _, _}), do: true
  defp delta?(_), do: false

  # ── Accumulation + leading edge ──────────────────────────────────────────────

  @spec accumulate(state(), pid(), delta()) :: state()
  defp accumulate(state, session_pid, delta) do
    accumulate(state, session_pid, delta, session(state, session_pid))
  end

  @spec accumulate(state(), pid(), delta(), session_state()) :: state()
  # Leading edge: idle (no tick pending) means forward this delta immediately as
  # a one-element batch, then arm the window for the steady-state stream. AC 5.
  defp accumulate(state, session_pid, delta, %{timer: nil}) do
    forward_batch(state, session_pid, [delta], :leading)
    put_session(state, session_pid, %{pending: [], timer: arm(state, session_pid)})
  end

  # Steady state: a tick is already pending, so accumulate (reversed) and let the
  # tick flush the batch.
  defp accumulate(state, session_pid, delta, %{pending: pending} = sess) do
    put_session(state, session_pid, %{sess | pending: [delta | pending]})
  end

  # ── Flush ────────────────────────────────────────────────────────────────────

  @spec flush(state(), pid(), :tick | :control) :: state()
  defp flush(state, session_pid, reason) do
    flush(state, session_pid, reason, session(state, session_pid))
  end

  @spec flush(state(), pid(), :tick | :control, session_state()) :: state()
  defp flush(state, _session_pid, _reason, %{timer: nil, pending: []}), do: state

  defp flush(state, session_pid, reason, %{pending: pending, timer: timer}) do
    cancel(timer)

    case pending do
      [] -> :ok
      _ -> forward_bounded(state, session_pid, Enum.reverse(pending), reason)
    end

    # After a flush the session is idle again: the next delta re-arms the leading
    # edge. A flush triggered by the tick clears the timer; a flush triggered by
    # a control event also returns to idle so trailing text after the control
    # event coalesces fresh.
    put_session(state, session_pid, %{pending: [], timer: nil})
  end

  # ── Forwarding ───────────────────────────────────────────────────────────────

  @spec forward_bounded(state(), pid(), batch(), :leading | :tick | :control) :: :ok
  defp forward_bounded(state, session_pid, batch, reason) do
    batch
    |> chunk_batch(state.max_batch_items, state.max_batch_bytes)
    |> Enum.each(&forward_batch(state, session_pid, &1, reason))
  end

  @spec chunk_batch(batch(), pos_integer(), pos_integer()) :: [batch()]
  defp chunk_batch(batch, max_items, max_bytes) do
    chunk_batch(batch, max_items, max_bytes, [], 0, 0, [])
  end

  defp chunk_batch([], _max_items, _max_bytes, current, _count, _bytes, chunks) do
    case current do
      [] -> Enum.reverse(chunks)
      _ -> Enum.reverse([Enum.reverse(current) | chunks])
    end
  end

  defp chunk_batch([delta | rest], max_items, max_bytes, current, count, bytes, chunks) do
    delta_bytes = delta_byte_size(delta)
    new_count = count + 1
    new_bytes = bytes + delta_bytes

    if count > 0 and (new_count > max_items or new_bytes > max_bytes) do
      chunk_batch(
        [delta | rest],
        max_items,
        max_bytes,
        [],
        0,
        0,
        [Enum.reverse(current) | chunks]
      )
    else
      chunk_batch(rest, max_items, max_bytes, [delta | current], new_count, new_bytes, chunks)
    end
  end

  @spec delta_byte_size(delta()) :: non_neg_integer()
  defp delta_byte_size({:text_delta, text}) when is_binary(text), do: byte_size(text)
  defp delta_byte_size({:thinking_delta, text}) when is_binary(text), do: byte_size(text)

  defp delta_byte_size({:tool_update, _, _, value}) when is_binary(value),
    do: byte_size(value)

  defp delta_byte_size(_), do: 0

  @spec forward_batch(state(), pid(), batch(), :leading | :tick | :control) :: :ok
  defp forward_batch(%{editor: editor}, session_pid, batch, edge) do
    # A flush is a point event, not a spanned operation, so execute/3 rather
    # than span/3 is the right telemetry shape here.
    Minga.Telemetry.execute(@telemetry_flush, %{delta_count: Enum.count(batch)}, %{edge: edge})
    send(editor, {:agent_stream_batch, session_pid, batch})
    :ok
  end

  @spec forward_control(state(), pid(), term()) :: :ok
  defp forward_control(%{editor: editor}, session_pid, event) do
    send(editor, {:agent_event, session_pid, event})
    :ok
  end

  # ── Session bookkeeping ──────────────────────────────────────────────────────

  @spec do_subscribe(pid(), keyword()) :: :ok | {:error, term()}
  defp do_subscribe(session_pid, opts) do
    case Session.subscribe(session_pid, self(), opts, @session_subscribe_timeout_ms) do
      :ok ->
        # Monitor the session so its abrupt death (no control event) still drops
        # the per-session accumulation via the {:DOWN, ...} clause above. Only
        # monitor on a successful subscribe so a rejected subscribe leaves no
        # dangling monitor. Callers always pass a freshly started session pid
        # (start, background start, restart), so this cannot double-register;
        # even a duplicate :DOWN would be harmless since drop_session is
        # idempotent.
        Process.monitor(session_pid)
        :ok

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec session(state(), pid()) :: session_state()
  defp session(state, session_pid) do
    Map.get(state.sessions, session_pid, %{pending: [], timer: nil})
  end

  @spec put_session(state(), pid(), session_state()) :: state()
  defp put_session(state, session_pid, %{pending: [], timer: nil}) do
    %{state | sessions: Map.delete(state.sessions, session_pid)}
  end

  defp put_session(state, session_pid, sess) do
    %{state | sessions: Map.put(state.sessions, session_pid, sess)}
  end

  @spec drop_session(state(), pid()) :: state()
  defp drop_session(state, session_pid) do
    case Map.get(state.sessions, session_pid) do
      %{timer: timer} -> cancel(timer)
      _ -> :ok
    end

    %{state | sessions: Map.delete(state.sessions, session_pid)}
  end

  @spec arm(state(), pid()) :: reference()
  defp arm(%{window_ms: window_ms}, session_pid) do
    Process.send_after(self(), {:ingest_tick, session_pid}, window_ms)
  end

  @spec cancel(reference() | nil) :: :ok
  defp cancel(nil), do: :ok

  defp cancel(timer) do
    Process.cancel_timer(timer)
    :ok
  end
end
