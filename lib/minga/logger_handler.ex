defmodule Minga.LoggerHandler do
  @moduledoc """
  Custom `:logger` handler that routes log messages to the `*Messages*` buffer.

  When the TUI is active, the default console handler writes to stderr which
  corrupts the terminal display. This module:

  1. Replaces the default `:logger_std_h` handler with a file-based one
     (writes to `~/.local/share/minga/minga.log`)
  2. Adds a custom handler that forwards messages to the `*Messages*` buffer
     via `Minga.Editor.log_to_messages/1`
  3. Redirects the `:standard_error` IO device to the same log file so that
     raw BEAM warnings (e.g. `IO.warn/2`) don't corrupt the TUI either

  ## Crash recovery

  When the Editor GenServer is down (e.g., mid-restart after a crash), log
  messages are buffered in an ETS table owned by the Application supervisor.
  The Editor calls `flush_buffer/0` during `init/1` to replay them into
  `*Messages*`. The buffer is capped at `@max_buffered` entries to prevent
  unbounded growth during crash loops.

  ## Installation

  Called from `Minga.Editor.init/1` after the `*Messages*` buffer is ready:

      Minga.LoggerHandler.install()

  The handler stays installed across Editor restarts so that crash reports
  are captured in the ETS buffer. `uninstall/0` is called only during
  clean application shutdown (`Application.stop/1`).

  `install/0` is idempotent: safe to call on every `Editor.init/1` even
  when the handlers are already in place from a previous Editor lifetime.
  """

  @handler_id :minga_messages
  @file_handler_id :minga_file
  @log_dir Path.expand("~/.local/share/minga")
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
  Install the custom handlers and redirect stderr to a log file.

  Idempotent: skips any handler or redirect that is already in place.
  Safe to call on every `Editor.init/1`, including restarts after a crash
  where the handlers survived because `terminate/2` no longer tears them down.

  Returns the log file path for display in `*Messages*`.
  """
  @spec install() :: String.t()
  def install do
    log_path = Path.join(@log_dir, @log_file)
    File.mkdir_p!(@log_dir)

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
    unless handler_installed?(@handler_id) do
      :logger.add_handler(@handler_id, __MODULE__, %{level: :all})
    end

    # 3. Redirect :standard_error to the log file so IO.warn and raw BEAM
    #    warnings don't paint over the TUI. We open a unicode-mode file device
    #    and register it as :standard_error (the OTP IO protocol convention).
    #    Idempotent: skip if already redirected.
    unless stderr_redirected?() do
      redirect_standard_error(log_path)
    end

    log_path
  end

  @doc "Restore the default console handler and original stderr device."
  @spec uninstall() :: :ok
  def uninstall do
    :logger.remove_handler(@handler_id)
    :logger.remove_handler(@file_handler_id)
    restore_standard_error()

    # Re-add the stock console handler
    :logger.add_handler(:default, :logger_std_h, %{
      config: %{type: :standard_error}
    })

    :ok
  end

  @doc """
  Flush buffered log messages into the Editor.

  Called from `Editor.init/1` after `*Messages*` is ready. Replays all
  buffered messages in order, then clears the buffer. Messages that arrived
  while the Editor was down (e.g., supervisor crash reports) will appear
  in `*Messages*` as if they'd been logged normally.
  """
  @spec flush_buffer() :: non_neg_integer()
  def flush_buffer do
    case :ets.whereis(@buffer_table) do
      :undefined ->
        0

      _ref ->
        entries = :ets.tab2list(@buffer_table)
        :ets.delete_all_objects(@buffer_table)
        Enum.each(entries, &replay_entry/1)
        length(entries)
    end
  end

  @spec replay_entry({integer(), String.t(), atom()}) :: :ok
  defp replay_entry({_key, text, level}) do
    Minga.Editor.log_to_messages(text)

    if level in [:warning, :error] do
      Minga.Editor.log_to_warnings(text)
    end

    :ok
  end

  # ── :logger handler callbacks (OTP 21+) ────────────────────────────────────

  @doc false
  @spec adding_handler(:logger.handler_config()) :: {:ok, :logger.handler_config()}
  def adding_handler(config), do: {:ok, config}

  @doc false
  @spec removing_handler(:logger.handler_config()) :: :ok
  def removing_handler(_config), do: :ok

  @doc false
  @spec changing_config(:update | :set, :logger.handler_config(), :logger.handler_config()) ::
          {:ok, :logger.handler_config()}
  def changing_config(_action, _old, new), do: {:ok, new}

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    text = format_message(level, msg, meta)

    case Process.whereis(Minga.Editor) do
      nil ->
        buffer_message(text, level)

      _pid ->
        Minga.Editor.log_to_messages(text)

        if level in [:warning, :error] do
          Minga.Editor.log_to_warnings(text)
        end
    end
  end

  # ── Buffer for messages during Editor downtime ─────────────────────────────

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

  # ── stderr redirect ────────────────────────────────────────────────────────

  @spec redirect_standard_error(String.t()) :: :ok
  defp redirect_standard_error(log_path) do
    # Stash the original device so we can restore it later.
    case Process.whereis(:standard_error) do
      nil ->
        :ok

      original ->
        :persistent_term.put(:minga_original_stderr, original)
        {:ok, file} = File.open(log_path, [:append, :utf8])
        :persistent_term.put(:minga_stderr_file, file)

        # Swap the registered name. Any process writing to :standard_error
        # (including IO.warn) will now hit our file device instead.
        Process.unregister(:standard_error)
        Process.register(file, :standard_error)
    end

    :ok
  end

  @spec restore_standard_error() :: :ok
  defp restore_standard_error do
    try do
      original = :persistent_term.get(:minga_original_stderr)
      file = :persistent_term.get(:minga_stderr_file)

      Process.unregister(:standard_error)
      Process.register(original, :standard_error)
      File.close(file)

      :persistent_term.erase(:minga_original_stderr)
      :persistent_term.erase(:minga_stderr_file)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ── Message formatting ─────────────────────────────────────────────────────

  @spec format_message(atom(), term(), map()) :: String.t()
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

  @spec stderr_redirected?() :: boolean()
  defp stderr_redirected? do
    :persistent_term.get(:minga_original_stderr, nil) != nil
  end
end
