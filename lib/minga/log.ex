defmodule Minga.Log do
  @moduledoc """
  Per-subsystem logging with configurable log levels.

  Wraps `Logger` with subsystem-aware filtering. Each subsystem has its
  own log level option (e.g., `:log_level_render`) that defaults to
  `:default`, meaning "inherit from the global `:log_level` option."

  ## Subsystems

  | Subsystem  | Option              | What it covers                           |
  |------------|---------------------|------------------------------------------|
  | `:render`  | `:log_level_render` | Render pipeline stage timing             |
  | `:lsp`     | `:log_level_lsp`    | LSP client communication and errors      |
  | `:agent`   | `:log_level_agent`  | AI agent providers and sessions          |
  | `:editor`  | `:log_level_editor` | General editor operations and commands   |
  | `:config`  | `:log_level_config` | Config loading, hooks, advice, extensions|
  | `:port`    | `:log_level_port`   | Port/parser process management            |

  ## Usage

      Minga.Log.debug(:render, "[render:content] 24µs")
      Minga.Log.info(:agent, "[Agent] session started")
      Minga.Log.warning(:lsp, "LSP server crashed")

  ## Configuration

  In your `config.exs`:

      # Global default: suppress debug logs
      set :log_level, :info

      # Turn on debug logging just for the render pipeline
      set :log_level_render, :debug
  """

  require Logger

  alias Minga.Config.Options

  @type subsystem :: :render | :lsp | :agent | :editor | :config | :port

  @type level :: :debug | :info | :warning | :error

  @level_priority %{
    debug: 0,
    info: 1,
    warning: 2,
    error: 3,
    none: 4
  }

  @subsystem_options %{
    render: :log_level_render,
    lsp: :log_level_lsp,
    agent: :log_level_agent,
    editor: :log_level_editor,
    config: :log_level_config,
    port: :log_level_port
  }

  @doc "Logs a debug message for the given subsystem (if its level permits)."
  @spec debug(subsystem(), String.t() | (-> String.t())) :: :ok
  def debug(subsystem, message_or_fun) do
    maybe_log(:debug, subsystem, message_or_fun)
  end

  @doc "Logs an info message for the given subsystem (if its level permits)."
  @spec info(subsystem(), String.t() | (-> String.t())) :: :ok
  def info(subsystem, message_or_fun) do
    maybe_log(:info, subsystem, message_or_fun)
  end

  @doc "Logs a warning message for the given subsystem (if its level permits)."
  @spec warning(subsystem(), String.t() | (-> String.t())) :: :ok
  def warning(subsystem, message_or_fun) do
    maybe_log(:warning, subsystem, message_or_fun)
  end

  @doc "Logs an error message for the given subsystem (if its level permits)."
  @spec error(subsystem(), String.t() | (-> String.t())) :: :ok
  def error(subsystem, message_or_fun) do
    maybe_log(:error, subsystem, message_or_fun)
  end

  @doc """
  Returns the effective log level for a subsystem.

  If the subsystem's option is `:default`, falls back to the global
  `:log_level` option.
  """
  @spec effective_level(subsystem()) :: :debug | :info | :warning | :error | :none
  def effective_level(subsystem) do
    option_name = Map.fetch!(@subsystem_options, subsystem)

    case safe_get_option(option_name) do
      :default -> safe_get_option(:log_level)
      level -> level
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec maybe_log(level(), subsystem(), String.t() | (-> String.t())) :: :ok
  defp maybe_log(level, subsystem, message_or_fun) do
    min_level = effective_level(subsystem)
    msg_priority = Map.fetch!(@level_priority, level)
    min_priority = Map.fetch!(@level_priority, min_level)

    if msg_priority >= min_priority do
      message =
        case message_or_fun do
          fun when is_function(fun, 0) -> fun.()
          msg when is_binary(msg) -> msg
        end

      case level do
        :debug -> Logger.debug(message)
        :info -> Logger.info(message)
        :warning -> Logger.warning(message)
        :error -> Logger.error(message)
      end
    end

    :ok
  end

  @spec safe_get_option(Options.option_name()) :: atom()
  defp safe_get_option(name) do
    Options.get(name)
  rescue
    # Options agent may not be running (e.g., early startup or tests
    # that don't start the application). Fall back to sensible defaults.
    _ ->
      case name do
        :log_level -> :info
        _ -> :default
      end
  end
end
