defmodule Minga.UserPaths do
  @moduledoc "Runtime roots for Minga's per-user config and data."

  @doc "Returns the config directory, or `nil` when no user home is available."
  @spec config_dir() :: String.t() | nil
  def config_dir do
    case absolute_env("XDG_CONFIG_HOME") do
      nil -> home_config_dir(System.user_home())
      root -> Path.join(root, "minga")
    end
  end

  @doc "Returns the config directory, raising when no user home is available."
  @spec config_dir!() :: String.t()
  def config_dir!, do: config_dir() || Path.expand("~/.config/minga")

  @doc "Returns the data directory."
  @spec data_dir() :: String.t()
  def data_dir do
    root = absolute_env("XDG_DATA_HOME") || Path.expand("~/.local/share")
    Path.join(root, "minga")
  end

  @spec absolute_env(String.t()) :: String.t() | nil
  defp absolute_env(name) do
    case System.get_env(name) do
      nil -> nil
      path -> if Path.type(path) == :absolute, do: path
    end
  end

  @spec home_config_dir(String.t() | nil) :: String.t() | nil
  defp home_config_dir(nil), do: nil
  defp home_config_dir(home), do: Path.join([home, ".config", "minga"])
end
