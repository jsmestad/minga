defmodule Minga.SafeModeTest do
  @moduledoc false

  # async: false — Minga.SafeMode.put/1 mutates Application env (global state).
  use ExUnit.Case, async: false

  test "startup_safe_mode? detects the env value '1'" do
    refute Minga.SafeMode.startup_safe_mode?(env_value: nil)
    assert Minga.SafeMode.startup_safe_mode?(env_value: "1")
    assert Minga.SafeMode.startup_safe_mode?(env_value: "true")
    refute Minga.SafeMode.startup_safe_mode?(env_value: "0")
  end

  test "active? returns true when application env is set" do
    previous_app_env = Application.get_env(:minga, :safe_mode)

    on_exit(fn ->
      restore_app_env(previous_app_env)
    end)

    Minga.SafeMode.put(true)
    assert Minga.SafeMode.active?()

    Minga.SafeMode.put(false)
    refute Minga.SafeMode.active?()
  end

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
