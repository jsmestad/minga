defmodule Minga.Bench.CheckLatencyBudgets do
  @moduledoc """
  Enforces keystroke latency budgets by comparing the latest bench output against
  configured ceilings (bench/latency_budgets.json).

  Reads the JSON output from `mix run bench/keystroke_latency_baseline.exs`
  (path: bench/baselines/keystroke_latency.json) and the budgets config, then exits
  nonzero with a clear breach report if any scenario exceeds its p50 or p99 ceiling.

  Run with: MIX_ENV=test mix run bench/check_latency_budgets.exs
  """

  @baseline_path Path.join([__DIR__, "baselines", "keystroke_latency.json"])
  @budgets_path Path.join([__DIR__, "latency_budgets.json"])

  @spec run() :: :ok | no_return()
  def run do
    baseline = load_json!(@baseline_path)
    budgets = load_json!(@budgets_path)

    breaches = check_scenarios(baseline, budgets)

    if Enum.empty?(breaches) do
      IO.puts("✓ All latency budgets within limits")
      :ok
    else
      IO.puts("\n✗ Latency budget breaches detected:\n")
      print_breaches(breaches)
      System.halt(1)
    end
  end

  @spec check_scenarios(map(), map()) :: [map()]
  defp check_scenarios(baseline, budgets) do
    baseline_scenarios = Map.get(baseline, "scenarios", %{})
    budget_scenarios = Map.get(budgets, "scenarios", %{})

    Enum.flat_map(baseline_scenarios, fn {scenario_name, measured} ->
      budget = Map.get(budget_scenarios, scenario_name, %{})

      [
        {"p50_us", "p50"},
        {"p99_us", "p99"}
      ]
      |> Enum.flat_map(fn {key, label} ->
        check_metric(scenario_name, label, Map.get(measured, key), Map.get(budget, key))
      end)
    end)
  end

  @spec check_metric(String.t(), String.t(), number() | nil, number() | nil) :: [map()]
  defp check_metric(scenario, label, nil, _budget),
    do: [%{scenario: scenario, field: label, error: "no measurement found"}]

  defp check_metric(scenario, label, _measured, nil),
    do: [%{scenario: scenario, field: label, error: "no budget configured"}]

  defp check_metric(scenario, label, measured, budget) when measured > budget do
    [
      %{
        scenario: scenario,
        field: label,
        measured: measured,
        budget: budget,
        excess_pct: round((measured - budget) / budget * 100)
      }
    ]
  end

  defp check_metric(_scenario, _label, _measured, _budget), do: []

  @spec print_breaches([map()]) :: :ok
  defp print_breaches(breaches) do
    Enum.each(breaches, fn breach ->
      case breach do
        %{error: error, scenario: scenario, field: field} ->
          IO.puts("  #{scenario}/#{field}: #{error}")

        %{scenario: scenario, field: field, measured: measured, budget: budget, excess_pct: pct} ->
          IO.puts("  #{scenario}/#{field}: #{measured}µs (budget: #{budget}µs, +#{pct}% over)")
      end
    end)

    :ok
  end

  @spec load_json!(String.t()) :: map()
  defp load_json!(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_json!(path, content)

      {:error, :enoent} ->
        IO.puts(
          :stderr,
          "Error: #{path} not found. Run `MIX_ENV=test mix run bench/keystroke_latency_baseline.exs` first."
        )

        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error reading #{path}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @spec decode_json!(String.t(), String.t()) :: map()
  defp decode_json!(path, content) do
    case JSON.decode(content) do
      {:ok, data} when is_map(data) ->
        data

      {:ok, other} ->
        IO.puts(:stderr, "Error: #{path} did not decode to a JSON object: #{inspect(other)}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error parsing #{path}: #{inspect(reason)}")
        System.halt(1)
    end
  end
end

Minga.Bench.CheckLatencyBudgets.run()
