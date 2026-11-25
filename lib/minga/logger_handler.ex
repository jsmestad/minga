defmodule Minga.LoggerHandler do
  @moduledoc """
  Custom `:logger` handler that routes log messages to the `*Messages*` buffer.

  When the TUI is active, the default console handler writes to stderr which
  corrupts the terminal display. This module:

  1. Replaces the default `:logger_std_h` handler with a file-based one
     (writes to `~/.local/share/minga/minga.log`)
  2. Adds a custom handler that forwards messages to the `*Messages*` buffer
     via `Minga.Events` broadcasts
  3. Asks `Minga.LoggerHandler.StderrRedirect` to move the `:standard_error` device to the same log file, so compiler diagnostics, `IO.warn/1` and `IO.puts(:stderr, ...)` don't corrupt the TUI either. The holder owns the log-file device, not the caller, so the redirect survives an Editor crash

  ## Crash recovery

  When the Editor GenServer is down (e.g., mid-restart after a crash), log
  messages are buffered in an ETS table owned by the Application supervisor.
  The Editor calls `flush_buffer/0` during `init/1` to replay them into
  `*Messages*`. The buffer is capped at `@max_buffered` entries to prevent
  unbounded growth during crash loops.

  ## Installation

  Called before standalone TUI app start and again from the Editor's `init/1` after the `*Messages*` buffer is ready:

      Minga.LoggerHandler.install()

  The handler stays installed across Editor restarts so that crash reports
  are captured in the ETS buffer. `uninstall/0` is called only during
  clean application shutdown (`Application.stop/1`).

  `install/0` is idempotent: safe to call on every Editor init even
  when the handlers are already in place from a previous Editor lifetime.
  """

  alias Minga.LoggerHandler.StderrRedirect

  @handler_id :minga_messages
  @file_handler_id :minga_file
  @log_file "minga.log"
  @buffer_table :minga_log_buffer
  @max_buffered 50

  @doc """
  Creates the ETS buffer table if it doesn't already exist.

  Called from `Minga.Application.start/2` so the table is owned by the
  supervisor process and survives Editor crashes.
  """
  @spec ensure_buffer_table() :: :ok
  def ensure_buffer_table do
    case :ets.whereis(@buffer_table) do
      :undefined ->
        :ets.new(@buffer_table, [:named_table, :ordered_set, :public])
        :ok

      _ref ->
        :ok
    end
  end

  @doc """
  Install just the custom `:log_message`-broadcast handler.

  Called from `Minga.Application.start/2` and `Minga.Runtime.start/1` so the
  broadcast path is live before any editor (or the gateway, or the singleton
  `*Messages*` buffer owner) is up. Idempotent.

  Unlike `install/0`, this does not replace the default `:logger` handler
  and does not redirect stderr — those are TUI-only concerns and stay in
  the editor's init path so headless and `mix` invocations keep stdout/stderr
  output.
  """
  @spec install_messages_handler() :: :ok
  def install_messages_handler do
    unless handler_installed?(@handler_id) do
      :logger.add_handler(@handler_id, __MODULE__, %{level: :all})
    end

    :ok
  end

  @doc """
  Install the file handler and the standard error redirect for TUI mode.

  Idempotent: skips any handler or redirect that is already in place.
  Safe to call on every Editor init, including restarts after a crash
  where the handlers survived because `terminate/2` no longer tears them down.

  Also ensures the `:log_message` broadcast handler is installed (no-op if
  the application boot already added it).

  Returns the log file path for display in `*Messages*`.
  """
  @spec install() :: String.t()
  def install do
    log_dir = Minga.UserPaths.data_dir()
    log_path = Path.join(log_dir, @log_file)
    File.mkdir_p!(log_dir)
    ensure_buffer_table()

    # 1. Replace the default handler with a file-based one.
    #    Idempotent: skip if already installed (Editor restarting after a
    #    crash while the LoggerHandler stayed in place).
    unless handler_installed?(@file_handler_id) do
      :logger.remove_handler(:default)

      :logger.add_handler(@file_handler_id, :logger_std_h, %{
        config: %{type: {:file, String.to_charlist(log_path)}},
        level: :all
      })
    end

    # 2. Add our custom handler that sends to *Messages*.
    install_messages_handler()

    # 3. Redirect :standard_error to the log file, so compiler diagnostics and IO.warn don't paint over the TUI.
    #    The holder owns the log-file device, so the redirect outlives the Editor that asked for it.
    #    Idempotent in the holder.
    _result = StderrRedirect.redirect(log_path)

    log_path
  end

  @doc "Restore the default console handler and original stderr device."
  @spec uninstall() :: :ok
  def uninstall do
    :logger.remove_handler(@handler_id)
    :logger.remove_handler(@file_handler_id)
    StderrRedirect.restore()

    # Re-add the stock console handler
    :logger.add_handler(:default, :logger_std_h, %{
      config: %{type: :standard_error}
    })

    :ok
  end

  @doc """
  Flush buffered log messages into the Editor.

  Called from the Editor's `init/1` after `*Messages*` is ready. Replays all
  buffered messages in order, then clears the buffer. Messages that arrived
  while the Editor was down (e.g., supervisor crash reports) will appear
  in `*Messages*` as if they'd been logged normally.
  """
  @spec flush_buffer() :: [{String.t(), atom()}]
  def flush_buffer do
    case :ets.whereis(@buffer_table) do
      :undefined ->
        []

      _ref ->
        entries = :ets.tab2list(@buffer_table)
        :ets.delete_all_objects(@buffer_table)
        Enum.map(entries, fn {_key, text, level} -> {text, level} end)
    end
  end

  @doc "Removes all entries from the log buffer table."
  @spec clear_buffer() :: :ok
  def clear_buffer do
    :ets.delete_all_objects(@buffer_table)
    :ok
  end

  @doc "Inserts a pre-formatted entry into the log buffer table."
  @spec buffer_entry(String.t(), atom()) :: :ok
  def buffer_entry(text, level) when is_binary(text) and is_atom(level) do
    key = System.monotonic_time(:nanosecond)
    :ets.insert(@buffer_table, {key, text, level})
    :ok
  end

  # ── :logger handler callbacks (OTP 21+) ────────────────────────────────────

  @spec adding_handler(:logger.handler_config()) :: {:ok, :logger.handler_config()}
  def adding_handler(config), do: {:ok, config}

  @spec removing_handler(:logger.handler_config()) :: :ok
  def removing_handler(_config), do: :ok

  @spec changing_config(:update | :set, :logger.handler_config(), :logger.handler_config()) ::
          {:ok, :logger.handler_config()}
  def changing_config(_action, _old, new), do: {:ok, new}

  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    text = format_message(level, msg, meta)

    # Buffer when the Events registry isn't yet up (very early boot, before
    # Foundation.Supervisor has started) or when no subscribers are listening
    # yet (Minga.Log.MessagesBuffer hasn't booted). Once the wrapper subscribes,
    # broadcasts reach it directly and the ETS buffer is drained on its init.
    if has_subscribers?() do
      Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
        text: text,
        level: event_level(level)
      })
    else
      buffer_message(text, level)
    end
  end

  @spec event_level(atom()) :: Minga.Events.LogMessageEvent.level()
  defp event_level(level) when level in [:error, :critical, :alert, :emergency], do: :error
  defp event_level(:warning), do: :warning
  defp event_level(:debug), do: :debug
  defp event_level(_level), do: :info

  @spec has_subscribers?() :: boolean()
  defp has_subscribers? do
    Minga.Events.subscribers(:log_message) != []
  rescue
    # Registry.lookup/2 raises ArgumentError when the Events registry
    # isn't started yet, which is expected during the very first phase
    # of Application boot. Treat it as "no subscribers"; the entry will
    # land in the LoggerHandler ETS pre-buffer and get drained by
    # Minga.Log.MessagesBuffer on init.
    ArgumentError -> false
  end

  # ── Buffer messages until the messages buffer subscriber is ready ──────────

  @spec buffer_message(String.t(), atom()) :: :ok
  defp buffer_message(text, level) do
    case :ets.whereis(@buffer_table) do
      :undefined ->
        :ok

      _ref ->
        key = System.monotonic_time(:nanosecond)
        :ets.insert(@buffer_table, {key, text, level})
        maybe_trim_buffer()
    end
  end

  @spec maybe_trim_buffer() :: :ok
  defp maybe_trim_buffer do
    size = :ets.info(@buffer_table, :size)

    if size > @max_buffered do
      delete_oldest(size - @max_buffered)
    end

    :ok
  end

  @spec delete_oldest(non_neg_integer()) :: :ok
  defp delete_oldest(0), do: :ok

  defp delete_oldest(remaining) do
    case :ets.first(@buffer_table) do
      :"$end_of_table" ->
        :ok

      key ->
        :ets.delete(@buffer_table, key)
        delete_oldest(remaining - 1)
    end
  end

  # ── Message formatting ─────────────────────────────────────────────────────

  @spec format_message(atom(), term(), map()) :: String.t()
  defp format_message(level, {:string, msg}, %{minga_gui: true}) do
    "[GUI/#{level}] #{IO.iodata_to_binary(msg)}"
  end

  defp format_message(level, {:string, msg}, _meta) do
    "[#{level}] #{IO.iodata_to_binary(msg)}"
  end

  defp format_message(level, {:report, report}, _meta) do
    "[#{level}] #{inspect(report)}"
  end

  defp format_message(level, {format, args}, _meta) do
    "[#{level}] #{:io_lib.format(format, args) |> IO.iodata_to_binary()}"
  end

  # ── Idempotency helpers ────────────────────────────────────────────────────

  @spec handler_installed?(atom()) :: boolean()
  defp handler_installed?(handler_id) do
    match?({:ok, _}, :logger.get_handler_config(handler_id))
  end
end
