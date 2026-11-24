defmodule MingaEditor.Watchdog do
  @moduledoc """
  Out-of-band recovery and stall detection for the Editor GenServer.

  Registers for SIGUSR2 via `:os.set_signal/2` and `erl_signal_server`. When the renderer or macOS GUI detects that the BEAM is unresponsive, it sends SIGUSR2 to the parent BEAM OS process. The signal handler forwards it to the Watchdog as a `{:signal, :sigusr2}` message, which kills the Editor GenServer and lets the supervisor restart it.

  ## Stall sampler

  Every `:sample_interval_ms` (default 100 ms), the Watchdog reads the
  Editor's message queue length, status, and stack trace via
  `Process.info/2` (a read-only call that sends nothing to the Editor).
  When the queue has items on two consecutive samples AND the Editor
  appears stuck (waiting in receive, or the stack has not changed while
  the queue did not shrink), one warning is logged. The warning is not
  repeated until the queue drains to zero (re-arm).

  Healthy bursts (such as agent text streaming) do not trigger a warning
  because the queue drains between samples.

  ## Why a separate process?

  If the Editor GenServer is stuck (long-running callback, deadlock),
  it can't process messages from its own mailbox. The Watchdog is a
  sibling process with its own mailbox, so it can act even when the
  Editor is completely unresponsive.

  ## Supervision placement

  The Watchdog is an independent leaf child of `Runtime.Supervisor`
  (`one_for_one`), placed before `MingaEditor.Supervisor` so it's ready to
  receive signals from the moment the Editor boots. Under `one_for_one`,
  a Watchdog crash restarts only itself without affecting FileWatcher
  or MingaEditor.Supervisor.
  """

  use GenServer
  alias Minga.Log
  alias MingaEditor.Watchdog.SignalHandler

  @default_sample_interval_ms 100

  @typedoc "Options for starting the watchdog."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:editor_name, GenServer.name()}
          | {:sample_interval_ms, pos_integer()}

  @type state :: %{
          editor_name: GenServer.name(),
          sample_interval_ms: pos_integer(),
          sample_timer: reference() | nil,
          prev_queue_len: non_neg_integer(),
          prev_stack: list() | nil,
          stall_reported: boolean()
        }

  # ── Client API ──────────────────────────────────────────────────────────

  @doc "Starts the watchdog process."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── Server Callbacks ────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    editor_name = Keyword.get(opts, :editor_name, MingaEditor)
    sample_interval_ms = Keyword.get(opts, :sample_interval_ms, @default_sample_interval_ms)

    # OTP's built-in erl_signal_handler reserves SIGUSR1 for crash-dump shutdown.
    # SIGUSR2 is otherwise ignored, so Minga handles it through erl_signal_server.
    :ok = :os.set_signal(:sigusr2, :handle)
    :ok = :gen_event.add_sup_handler(:erl_signal_server, {SignalHandler, self()}, self())

    Log.info(:editor, "Watchdog started, listening for SIGUSR2")

    timer = schedule_sample(sample_interval_ms)

    {:ok,
     %{
       editor_name: editor_name,
       sample_interval_ms: sample_interval_ms,
       sample_timer: timer,
       prev_queue_len: 0,
       prev_stack: nil,
       stall_reported: false
     }}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:signal, :sigusr2}, state) do
    Log.warning(:editor, "Watchdog received SIGUSR2, killing Editor for recovery")

    case Process.whereis(state.editor_name) do
      nil ->
        Log.warning(:editor, "Watchdog: Editor process not found, nothing to kill")

      pid ->
        Process.exit(pid, :kill)
        Log.info(:editor, "Watchdog: Editor process #{inspect(pid)} killed")
    end

    {:noreply, state}
  end

  def handle_info(:sample, state) do
    state = do_sample(state)
    timer = schedule_sample(state.sample_interval_ms)
    {:noreply, %{state | sample_timer: timer}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Stall Detection ────────────────────────────────────────────────────

  @spec do_sample(state()) :: state()
  defp do_sample(state) do
    case Process.whereis(state.editor_name) do
      nil ->
        reset_sample_state(state)

      pid ->
        case Process.info(pid, [:message_queue_len, :status, :current_stacktrace]) do
          nil ->
            reset_sample_state(state)

          info ->
            queue_len = Keyword.fetch!(info, :message_queue_len)
            status = Keyword.fetch!(info, :status)
            stack = Keyword.fetch!(info, :current_stacktrace)

            evaluate_stall(state, queue_len, status, stack)
        end
    end
  end

  @spec evaluate_stall(state(), non_neg_integer(), atom(), list()) :: state()
  defp evaluate_stall(state, queue_len, status, stack) do
    cond do
      queue_len == 0 ->
        %{state | prev_queue_len: 0, prev_stack: stack, stall_reported: false}

      state.prev_queue_len > 0 and not state.stall_reported and
          stuck?(state, status, queue_len, stack) ->
        Log.warning(:editor, format_stall_warning(queue_len, stack))
        %{state | prev_queue_len: queue_len, prev_stack: stack, stall_reported: true}

      true ->
        %{state | prev_queue_len: queue_len, prev_stack: stack}
    end
  end

  @spec stuck?(state(), atom(), non_neg_integer(), list()) :: boolean()
  defp stuck?(state, status, queue_len, stack) do
    status == :waiting or (stack == state.prev_stack and queue_len >= state.prev_queue_len)
  end

  @spec format_stall_warning(non_neg_integer(), list()) :: String.t()
  defp format_stall_warning(queue_len, stack) do
    top_frames =
      stack
      |> Enum.take(5)
      |> Enum.map_join("\n  ", &Exception.format_stacktrace_entry/1)

    "Editor stall detected (#{queue_len} messages queued). Top frames:\n  #{top_frames}"
  end

  @spec reset_sample_state(state()) :: state()
  defp reset_sample_state(state) do
    %{state | prev_queue_len: 0, prev_stack: nil, stall_reported: false}
  end

  @spec schedule_sample(pos_integer()) :: reference()
  defp schedule_sample(interval_ms) do
    Process.send_after(self(), :sample, interval_ms)
  end
end
