defmodule MingaEditor.Watchdog.SignalHandler do
  @moduledoc """
  Forwards the BEAM's recovery signal from `erl_signal_server` to the Watchdog.

  SIGUSR1 cannot be used here because OTP's built-in signal handler reserves it for an immediate crash-dump shutdown. SIGUSR2 is otherwise ignored by OTP and is safe for Minga's out-of-band editor recovery path.
  """

  @behaviour :gen_event

  @type state :: pid()

  @impl true
  @spec init(pid()) :: {:ok, state()}
  def init(watchdog) when is_pid(watchdog), do: {:ok, watchdog}

  @impl true
  @spec handle_event(term(), state()) :: {:ok, state()}
  def handle_event(:sigusr2, watchdog) do
    send(watchdog, {:signal, :sigusr2})
    {:ok, watchdog}
  end

  def handle_event(_signal, watchdog), do: {:ok, watchdog}

  @impl true
  @spec handle_call(term(), state()) :: {:ok, :ok, state()}
  def handle_call(_request, watchdog), do: {:ok, :ok, watchdog}

  @impl true
  @spec handle_info(term(), state()) :: {:ok, state()}
  def handle_info(_message, watchdog), do: {:ok, watchdog}

  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, _watchdog), do: :ok

  @impl true
  @spec code_change(term(), state(), term()) :: {:ok, state()}
  def code_change(_old_version, watchdog, _extra), do: {:ok, watchdog}
end
