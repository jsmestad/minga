defmodule Minga.Test.OptionsHelper do
  @moduledoc """
  Helpers for safely resetting `Minga.Config.Options` in tests.

  `Options.reset/0` restores every option to its compile-time default,
  including `:clipboard` → `:unnamedplus`. That default causes the
  Clipboard mock to be called unexpectedly in async tests that trigger
  register operations. This module provides `reset_for_test/0` which
  resets and then re-applies overrides that the test environment needs.

  Use this instead of calling `Options.reset()` directly.
  """

  alias Minga.Config.Options

  # Options that must stay overridden in the test environment.
  # Clipboard is :none so register operations don't call the Clipboard
  # mock unless a test explicitly opts in via DI.
  @test_overrides [clipboard: :none]

  @doc """
  Resets Options to defaults, then re-applies test-time overrides.

  Accepts an optional server argument for tests that run their own
  private Options Agent.
  """
  @spec reset_for_test(GenServer.server()) :: :ok
  def reset_for_test(server \\ Options) do
    Options.reset(server)

    for {key, val} <- @test_overrides do
      Options.set(server, key, val)
    end

    :ok
  end
end
