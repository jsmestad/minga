defmodule Minga.SafeModeTest do
  @moduledoc false

  # Mutates process-wide env vars and application env used during startup detection.
  use ExUnit.Case, async: false

  test "active? sees MINGA_SAFE_MODE before loader startup" do
    previous_env = System.get_env("MINGA_SAFE_MODE")
    previous_app_env = Application.get_env(:minga, :safe_mode)

    on_exit(fn ->
      restore_env("MINGA_SAFE_MODE", previous_env)
      restore_app_env(previous_app_env)
    end)

    System.put_env("MINGA_SAFE_MODE", "1")
    Minga.SafeMode.put(false)

    assert Minga.SafeMode.startup_safe_mode?()
    assert Minga.SafeMode.active?()
  end

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  @spec restore_app_env(boolean() | nil) :: :ok
  defp restore_app_env(nil) do
    Minga.SafeMode.put(false)
  end

  defp restore_app_env(true) do
    Minga.SafeMode.put(true)
  end

  defp restore_app_env(false) do
    Minga.SafeMode.put(false)
  end
end
