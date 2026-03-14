defmodule Minga.Editor.Watchdog do
  @moduledoc """
  Out-of-band recovery process for the Editor GenServer.

  Registers for SIGUSR1 via `:os.set_signal/2`. When the Zig
  renderer (or macOS GUI) detects that the BEAM is unresponsive, it sends
  SIGUSR1 to the parent BEAM OS process. The Watchdog receives the signal
  as a `{:signal, :sigusr1}` message and kills the Editor GenServer,
  letting the supervisor restart it.

  This process has no periodic work. It exists solely to receive the
  out-of-band kill signal when the normal protocol channel is blocked.

  ## Why a separate process?

  If the Editor GenServer is stuck (long-running callback, deadlock),
  it can't process messages from its own mailbox. The Watchdog is a
  sibling process with its own mailbox, so it can act even when the
  Editor is completely unresponsive.

  ## Supervision placement

  The Watchdog must start before the Editor in the supervision tree
  so it's ready to receive signals from the moment the Editor boots.
  It sits alongside the Editor under the `rest_for_one` supervisor.
  If the Watchdog itself crashes, it gets restarted independently
  (it has no dependencies on other processes).
  """

  use GenServer

  require Logger

  @typedoc "Options for starting the watchdog."
  @type start_opt :: {:name, GenServer.name()} | {:editor_name, GenServer.name()}

  @type state :: %{
          editor_name: GenServer.name()
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
    editor_name = Keyword.get(opts, :editor_name, Minga.Editor)

    # Register for SIGUSR1. OTP 26+ delivers signals as messages
    # to the calling process: {:signal, :sigusr1}
    :os.set_signal(:sigusr1, :handle)

    Minga.Log.info(:editor, "Watchdog started, listening for SIGUSR1")

    {:ok, %{editor_name: editor_name}}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:signal, :sigusr1}, state) do
    Minga.Log.warning(:editor, "Watchdog received SIGUSR1, killing Editor for recovery")

    case Process.whereis(state.editor_name) do
      nil ->
        Minga.Log.warning(:editor, "Watchdog: Editor process not found, nothing to kill")

      pid ->
        Process.exit(pid, :kill)
        Minga.Log.info(:editor, "Watchdog: Editor process #{inspect(pid)} killed")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
