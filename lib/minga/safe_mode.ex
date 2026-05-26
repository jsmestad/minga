defmodule Minga.SafeMode do
  @moduledoc """
  Tracks whether the current Minga process started in safe mode.

  Safe mode is a startup recovery switch. When active, user config, user modules, project config, after hooks, and extensions are skipped during initial config loading so the editor can boot with defaults.

  Startup can request safe mode through `MINGA_SAFE_MODE=1`, `--safe`/`-Q` in the raw argv, or by setting the application env before startup.
  """

  @env_key :safe_mode

  @doc "Returns true when this process was started with safe mode enabled."
  @spec active?() :: boolean()
  def active? do
    Application.get_env(:minga, @env_key, false) == true or startup_safe_mode?()
  end

  @doc "Returns true when startup env or argv requested safe mode."
  @spec startup_safe_mode?() :: boolean()
  def startup_safe_mode? do
    startup_env_safe?() or startup_argv_safe?()
  end

  @doc "Stores the safe mode startup flag."
  @spec put(boolean()) :: :ok
  def put(true) do
    Application.put_env(:minga, @env_key, true)
    :ok
  end

  def put(false) do
    Application.delete_env(:minga, @env_key)
    :ok
  end

  @spec startup_env_safe?() :: boolean()
  defp startup_env_safe? do
    case System.get_env("MINGA_SAFE_MODE") do
      "1" -> true
      "true" -> true
      _ -> false
    end
  end

  @spec startup_argv_safe?() :: boolean()
  defp startup_argv_safe? do
    safe_args?(System.argv()) or burrito_safe_args?()
  rescue
    _ -> false
  end

  @spec burrito_safe_args?() :: boolean()
  defp burrito_safe_args? do
    if Burrito.Util.running_standalone?() do
      safe_args?(Burrito.Util.Args.argv())
    else
      false
    end
  rescue
    _ -> false
  end

  @spec safe_args?([String.t()]) :: boolean()
  defp safe_args?(args) do
    Enum.member?(args, "--safe") or Enum.member?(args, "-Q")
  end
end
