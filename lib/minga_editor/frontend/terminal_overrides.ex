defmodule MingaEditor.Frontend.TerminalOverrides do
  @moduledoc """
  The terminal features a user forces on or off, as the terminal frontend receives them.

  Detection can be wrong in ways the frontend cannot see: its table of known terminals goes stale, a terminal's refusal of a query never arrives, and a remote shell loses the variables that describe the terminal. The `:terminal_features` option says what to use anyway.

  The choice is an input to detection, so it reaches the frontend when the frontend starts, as an environment variable, and not as a command later: some features are set up once at startup, and a value that changed after it settled would make the report disagree with what is drawn. A changed option therefore applies the next time Minga starts. Where something other than the BEAM starts the frontend (connected mode), the BEAM cannot set the variable; a user sets it by hand.

  `:checkhealth terminal` shows a forced feature as set by the user, and says so when the option names a feature the running frontend was not started with.
  """

  alias Minga.Config.Options

  @variable "MINGA_TERMINAL_FEATURES"

  @typedoc "What the user forced: a feature mapped to `:on` or `:off`."
  @type t :: %{optional(atom()) => :on | :off}

  @doc "The environment variable the terminal frontend reads."
  @spec variable() :: String.t()
  def variable, do: @variable

  @doc """
  Returns the environment entries that hand `overrides` to the terminal frontend, for a port's `:env` option.

  The value is `feature=on` and `feature=off` entries separated by commas, sorted by feature. No override means no variable, so a variable the user set by hand is inherited unchanged.
  """
  @spec env(t()) :: [{charlist(), charlist()}]
  def env(overrides) when map_size(overrides) == 0, do: []

  def env(overrides) when is_map(overrides) do
    value =
      overrides
      |> Enum.sort()
      |> Enum.map_join(",", fn {feature, setting} -> "#{feature}=#{setting}" end)

    [{String.to_charlist(@variable), String.to_charlist(value)}]
  end

  @doc "Returns what the `:terminal_features` option forces. An options server that is not running forces nothing."
  @spec configured() :: t()
  @spec configured(Options.server()) :: t()
  def configured(server \\ Options) do
    Options.get(server, :terminal_features)
  rescue
    # The options table does not exist: the options server is not running.
    ArgumentError -> %{}
  catch
    :exit, _reason -> %{}
  end

  @doc "Returns the environment entries for what the `:terminal_features` option forces now."
  @spec launch_env() :: [{charlist(), charlist()}]
  def launch_env, do: env(configured())
end
