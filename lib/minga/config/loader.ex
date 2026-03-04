defmodule Minga.Config.Loader do
  @moduledoc """
  Discovers and evaluates the user's config file at startup.

  Looks for `config.exs` in `$XDG_CONFIG_HOME/minga/` (falling back to
  `~/.config/minga/`). The file is evaluated with `Code.eval_file/1`, so
  it's real Elixir. Errors (syntax or runtime) are captured and stored
  for the editor to display as a status bar warning.

  ## Config file location

  1. `$XDG_CONFIG_HOME/minga/config.exs` (if `$XDG_CONFIG_HOME` is set)
  2. `~/.config/minga/config.exs`

  If the file doesn't exist, the editor starts with defaults. No error,
  no warning.
  """

  use Agent

  require Logger

  @typedoc "Loader state: stores the resolved config path and any load error."
  @type state :: %{
          config_path: String.t(),
          load_error: String.t() | nil
        }

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the loader and evaluates the config file."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    Agent.start_link(fn -> load_config() end, name: name)
  end

  @doc """
  Returns the resolved config file path.

  This path is used by `SPC f p` to open the config file for editing.
  """
  @spec config_path() :: String.t()
  @spec config_path(GenServer.server()) :: String.t()
  def config_path, do: config_path(__MODULE__)
  def config_path(server), do: Agent.get(server, & &1.config_path)

  @doc """
  Returns the last config load error, or `nil` if config loaded cleanly
  (or no config file exists).
  """
  @spec load_error() :: String.t() | nil
  @spec load_error(GenServer.server()) :: String.t() | nil
  def load_error, do: load_error(__MODULE__)
  def load_error(server), do: Agent.get(server, & &1.load_error)

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec load_config() :: state()
  defp load_config do
    path = resolve_config_path()

    error =
      if File.exists?(path) do
        eval_config_file(path)
      else
        nil
      end

    %{config_path: path, load_error: error}
  end

  @spec resolve_config_path() :: String.t()
  defp resolve_config_path do
    base =
      case System.get_env("XDG_CONFIG_HOME") do
        nil -> Path.expand("~/.config")
        "" -> Path.expand("~/.config")
        dir -> dir
      end

    Path.join([base, "minga", "config.exs"])
  end

  @spec eval_config_file(String.t()) :: String.t() | nil
  defp eval_config_file(path) do
    Code.eval_file(path)
    nil
  rescue
    e in [SyntaxError, TokenMissingError, CompileError] ->
      msg = "Config syntax error: #{Exception.message(e)}"
      Logger.warning(msg)
      msg

    e ->
      msg = "Config error: #{Exception.message(e)}"
      Logger.warning(msg)
      msg
  catch
    kind, reason ->
      msg = "Config error: #{inspect(kind)} #{inspect(reason)}"
      Logger.warning(msg)
      msg
  end
end
