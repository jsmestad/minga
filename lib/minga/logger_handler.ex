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

  ## Installation

  Called from `Minga.Editor.init/1` after the `*Messages*` buffer is ready:

      Minga.LoggerHandler.install()

  The editor's `terminate/2` calls `uninstall/0` to restore defaults.
  """

  @handler_id :minga_messages
  @file_handler_id :minga_file
  @log_dir Path.expand("~/.local/share/minga")
  @log_file "minga.log"

  @doc """
  Install the custom handlers and redirect stderr to a log file.

  Returns the log file path for display in `*Messages*`.
  """
  @spec install() :: String.t()
  def install do
    log_path = Path.join(@log_dir, @log_file)
    File.mkdir_p!(@log_dir)

    # 1. Replace the default handler with a file-based one.
    #    Can't change type on a live handler, so remove + re-add.
    :logger.remove_handler(:default)

    :logger.add_handler(@file_handler_id, :logger_std_h, %{
      config: %{type: {:file, String.to_charlist(log_path)}},
      level: :all
    })

    # 2. Add our custom handler that sends to *Messages*.
    :logger.add_handler(@handler_id, __MODULE__, %{level: :all})

    # 3. Redirect :standard_error to the log file so IO.warn and raw BEAM
    #    warnings don't paint over the TUI. We open a unicode-mode file device
    #    and register it as :standard_error (the OTP IO protocol convention).
    redirect_standard_error(log_path)

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
        :ok

      _pid ->
        Minga.Editor.log_to_messages(text)

        if level in [:warning, :error] do
          Minga.Editor.log_to_warnings(text)
        end
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
end
