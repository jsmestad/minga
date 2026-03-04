defmodule Minga.Config do
  @moduledoc """
  DSL module for Minga user configuration.

  Used in `~/.config/minga/config.exs` (or `$XDG_CONFIG_HOME/minga/config.exs`)
  to declare editor options. The config file is real Elixir code evaluated at
  startup.

  ## Example config file

      use Minga.Config

      set :tab_width, 4
      set :line_numbers, :relative
      set :autopair, false
      set :scroll_margin, 8

  ## Available options

  See `Minga.Config.Options` for the full list of supported options and their
  types.
  """

  @doc """
  Injects the config DSL into the calling module or script.

  Imports `Minga.Config` so that `set/2` (and future DSL functions like
  `bind/4`, `command/3`, `on/2`) are available without qualification.
  """
  defmacro __using__(_opts) do
    quote do
      import Minga.Config
    end
  end

  alias Minga.Config.Options

  @doc """
  Sets an editor option.

  Validates the option name and value type, then stores the value in
  `Minga.Config.Options`. Raises `ArgumentError` if the option name is
  unknown or the value has the wrong type.

  ## Examples

      set :tab_width, 4
      set :line_numbers, :relative
  """
  @spec set(Options.option_name(), term()) :: :ok
  def set(name, value) when is_atom(name) do
    case Options.set(name, value) do
      {:ok, _} -> :ok
      {:error, msg} -> raise ArgumentError, msg
    end
  end
end
