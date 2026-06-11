defmodule MingaEditor.Agent.IngestTest do
  @moduledoc """
  Coalescing contract for the agent stream ingest process (#2289).

  Ingest sits between `MingaAgent.Session` and the Editor. These tests drive
  `{:agent_event, session_pid, event}` messages straight into the Ingest process
  (the same shape the session sends) with the test process standing in for the
  Editor, and assert on the `{:agent_stream_batch, ...}` / `{:agent_event, ...}`
  messages Ingest forwards. A large coalescing window plus a manually injected
  `{:ingest_tick, ...}` makes the steady-state flush deterministic without
  sleeping on the real timer.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Ingest

  # Minimal stand-in for `MingaAgent.Session`: answers the `{:subscribe, pid,
  # opts}` GenServer call with `:ok` so `Ingest.subscribe_session/3` (and the
  # `Process.monitor/1` it performs on success) exercise the real code path
  # without spinning up a full provider-backed session.
  defmodule StubSession do
    @moduledoc false
    use GenServer

    @spec start_link() :: GenServer.on_start()
    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    @impl true
    def init(:ok), do: {:ok, :ok}
    @impl true
    def handle_call({:subscribe, _pid, _opts}, _from, state), do: {:reply, :ok, state}
  end

  defp stub_session do
    {:ok, pid} = StubSession.start_link()
    # Unlink so a deliberate kill in the cleanup test does not take the test
    # process (and the Ingest link runs through Ingest, not us) down with it.
    Process.unlink(pid)
    pid
  end

  # Stand-in session pid: a live, harmless process so monitors and pid tagging
  # behave like the real thing.
  defp fake_session do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end

  defp start_ingest(window_ms) do
    # The test process is the Editor: batches and control events arrive here.
    start_supervised!({Ingest, editor: self(), window_ms: window_ms})
  end

  defp sync(pid), do: :sys.get_state(pid)

  # Takes the next message Ingest forwarded to us (the Editor), in mailbox order,
  # so ordering assertions are positional rather than selective.
  defp next_forwarded do
    receive do
      {:agent_stream_batch, _, _} = msg -> msg
      {:agent_event, _, _} = msg -> msg
    after
      500 -> flunk("expected a forwarded message but none arrived")
    end
  end

  describe "leading-edge flush (AC 5)" do
    test "the first delta after idle is forwarded immediately as a one-element batch" do
      ingest = start_ingest(10_000)
      session = fake_session()

      send(ingest, {:agent_event, session, {:text_delta, "hi"}})

      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "hi"}]}
    end

    test "a control event arriving while idle is forwarded with no spurious batch" do
      ingest = start_ingest(10_000)
      session = fake_session()

      send(ingest, {:agent_event, session, {:status_changed, :thinking}})

      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}
      refute_received {:agent_stream_batch, _, _}
    end
  end

  describe "steady-state coalescing (AC 2)" do
    test "N deltas within one window produce exactly one batch with all deltas in order" do
      ingest = start_ingest(10_000)
      session = fake_session()

      # First delta arms the window via the leading-edge flush.
      send(ingest, {:agent_event, session, {:text_delta, "0"}})
      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "0"}]}

      # These three accumulate while the window is open.
      send(ingest, {:agent_event, session, {:text_delta, "1"}})
      send(ingest, {:agent_event, session, {:thinking_delta, "2"}})
      send(ingest, {:agent_event, session, {:text_delta, "3"}})
      sync(ingest)

      # Fire the window tick. Exactly one batch carrying all three, in order.
      send(ingest, {:ingest_tick, session})

      assert_receive {:agent_stream_batch, ^session,
                      [{:text_delta, "1"}, {:thinking_delta, "2"}, {:text_delta, "3"}]}

      refute_received {:agent_stream_batch, _, _}
    end

    test "an empty window (only the leading delta) does not emit a trailing batch" do
      ingest = start_ingest(10_000)
      session = fake_session()

      send(ingest, {:agent_event, session, {:text_delta, "only"}})
      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "only"}]}

      send(ingest, {:ingest_tick, session})
      sync(ingest)

      refute_received {:agent_stream_batch, _, _}
    end
  end

  describe "control-event ordering (AC 3)" do
    test "a control event flushes the pending batch ahead of itself, in order" do
      ingest = start_ingest(10_000)
      session = fake_session()

      # Leading delta opens the window.
      send(ingest, {:agent_event, session, {:text_delta, "lead"}})
      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "lead"}]}

      # Trailing text accumulates, then turn-end arrives.
      send(ingest, {:agent_event, session, {:text_delta, "trailing"}})
      send(ingest, {:agent_event, session, {:status_changed, :idle}})
      sync(ingest)

      # Drain the mailbox in arrival order: the trailing-text batch must come
      # out STRICTLY BEFORE the turn-end control event, so the Editor never sees
      # a turn ending before that turn's text. Selective receive would hide a
      # reorder, so we take the next two messages positionally.
      assert next_forwarded() ==
               {:agent_stream_batch, session, [{:text_delta, "trailing"}]}

      assert next_forwarded() == {:agent_event, session, {:status_changed, :idle}}
    end

    test "after a control flush the next delta re-arms the leading edge immediately" do
      ingest = start_ingest(10_000)
      session = fake_session()

      send(ingest, {:agent_event, session, {:text_delta, "a"}})
      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "a"}]}

      send(ingest, {:agent_event, session, {:text_delta, "b"}})
      send(ingest, {:agent_event, session, {:tool_started, "shell", %{}}})
      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "b"}]}
      assert_receive {:agent_event, ^session, {:tool_started, "shell", %{}}}

      # Idle again: the next delta is a fresh leading edge, forwarded at once.
      send(ingest, {:agent_event, session, {:text_delta, "c"}})
      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "c"}]}
    end
  end

  describe "tick ordering relative to control flush" do
    test "a stale tick after a control flush does not emit an empty batch" do
      ingest = start_ingest(10_000)
      session = fake_session()

      send(ingest, {:agent_event, session, {:text_delta, "x"}})
      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "x"}]}

      send(ingest, {:agent_event, session, {:text_delta, "y"}})
      # Control event flushes "y" and cancels the armed tick.
      send(ingest, {:agent_event, session, {:status_changed, :idle}})
      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "y"}]}
      assert_receive {:agent_event, ^session, {:status_changed, :idle}}

      # A late tick (if the timer message had already been delivered) is a no-op.
      send(ingest, {:ingest_tick, session})
      sync(ingest)
      refute_received {:agent_stream_batch, _, _}
    end
  end

  describe "multiple sessions" do
    test "deltas from different sessions coalesce independently" do
      ingest = start_ingest(10_000)
      session_a = fake_session()
      session_b = fake_session()

      send(ingest, {:agent_event, session_a, {:text_delta, "a0"}})
      send(ingest, {:agent_event, session_b, {:text_delta, "b0"}})
      assert_receive {:agent_stream_batch, ^session_a, [{:text_delta, "a0"}]}
      assert_receive {:agent_stream_batch, ^session_b, [{:text_delta, "b0"}]}

      send(ingest, {:agent_event, session_a, {:text_delta, "a1"}})
      send(ingest, {:agent_event, session_b, {:text_delta, "b1"}})
      sync(ingest)

      send(ingest, {:ingest_tick, session_a})
      assert_receive {:agent_stream_batch, ^session_a, [{:text_delta, "a1"}]}
      # session_b's window is still open: no batch for it yet.
      refute_received {:agent_stream_batch, ^session_b, _}

      send(ingest, {:ingest_tick, session_b})
      assert_receive {:agent_stream_batch, ^session_b, [{:text_delta, "b1"}]}
    end
  end

  describe "session death cleanup" do
    test "an abruptly killed session (no control event) drops its accumulation entry" do
      ingest = start_ingest(10_000)
      session = stub_session()

      # Real subscribe path installs the Process.monitor on the session.
      assert :ok = Ingest.subscribe_session(ingest, session)

      # Open a window and accumulate so there is a live per-session entry (with an
      # armed timer) to clean up.
      send(ingest, {:agent_event, session, {:text_delta, "lead"}})
      assert_receive {:agent_stream_batch, ^session, [{:text_delta, "lead"}]}
      send(ingest, {:agent_event, session, {:text_delta, "trailing"}})
      sync(ingest)
      assert Map.has_key?(:sys.get_state(ingest).sessions, session)

      # Kill the session abruptly: no control event flows through Ingest, so the
      # only path that can drop the entry is the {:DOWN, ...} monitor message.
      ref = Process.monitor(session)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, _reason}

      # Sync once so Ingest processes its own :DOWN before we inspect state.
      sync(ingest)
      refute Map.has_key?(:sys.get_state(ingest).sessions, session)
    end
  end
end
