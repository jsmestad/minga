defmodule Minga.Conformance.ConformanceCaseTest do
  use ExUnit.Case, async: true

  alias Minga.Test.ConformanceCase

  defp scenario(overrides) do
    base = %{
      name: "scenario",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 0},
      keys: "dw",
      compare: [:content, :cursor, :mode, :register, :register_type]
    }

    Map.merge(base, overrides)
  end

  defp expected_result(overrides \\ %{}) do
    base = %{
      name: "scenario",
      ok: true,
      line: 0,
      col: 0,
      content: "two",
      mode: "normal",
      register: "one t",
      register_type: "v"
    }

    Map.merge(base, overrides)
  end

  test "stale known divergence now matching Neovim fails" do
    scenario =
      scenario(%{
        tags: [:known_divergence],
        known_divergence: %{
          reason: "expected divergence",
          failures: [:content],
          actual: %{content: "two"}
        }
      })

    expected = expected_result()
    actual = expected

    assert_raise ExUnit.AssertionError, fn ->
      ConformanceCase.compare_results(scenario, expected, actual)
    end
  end

  test "known divergence rejects changed failure fields" do
    scenario =
      scenario(%{
        tags: [:known_divergence],
        known_divergence: %{
          reason: "expected divergence",
          failures: [:cursor],
          actual: %{line: 0, col: 1}
        }
      })

    expected = expected_result()
    actual = expected_result(%{content: "wone to", col: 1})

    assert_raise ExUnit.AssertionError, fn ->
      ConformanceCase.compare_results(scenario, expected, actual)
    end
  end

  test "known divergence requires actual values for failing cursor fields" do
    scenario =
      scenario(%{
        tags: [:known_divergence],
        known_divergence: %{
          reason: "expected divergence",
          failures: [:cursor],
          actual: %{col: 1}
        }
      })

    expected = expected_result(%{col: 1})
    actual = expected_result(%{col: 1})

    assert_raise ExUnit.AssertionError, fn ->
      ConformanceCase.compare_results(scenario, expected, actual)
    end
  end

  test "known divergence rejects mismatched recorded actual values" do
    scenario =
      scenario(%{
        tags: [:known_divergence],
        known_divergence: %{
          reason: "expected divergence",
          failures: [:cursor],
          actual: %{line: 0, col: 1}
        }
      })

    expected = expected_result(%{col: 1})
    actual = expected_result(%{col: 2})

    assert_raise ExUnit.AssertionError, fn ->
      ConformanceCase.compare_results(scenario, expected, actual)
    end
  end

  test "known divergence failure fields are compared order-insensitively" do
    scenario =
      scenario(%{
        tags: [:known_divergence],
        compare: [:cursor, :content],
        known_divergence: %{
          reason: "expected divergence",
          failures: [:content, :cursor],
          actual: %{line: 0, col: 1, content: "wo"}
        }
      })

    expected = expected_result()
    actual = expected_result(%{content: "wo", col: 1})

    assert :ok = ConformanceCase.compare_results(scenario, expected, actual)
  end
end
