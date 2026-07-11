defmodule Minga.Bench.LatencyComparison do
  @moduledoc """
  Pure aggregation and comparison helpers for the keystroke latency A/B gate.

  A benchmark invocation is one round-level observation. CI runs both revisions
  repeatedly in alternating order, then compares the median observation for each
  scenario and metric. Keeping this logic independent from the benchmark runner
  makes the aggregation deterministic and directly testable.
  """

  @metrics [{"p50_us", "p50", "p50_pct"}, {"p99_us", "p99", "p99_pct"}]

  @spec metrics() :: [{String.t(), String.t(), String.t()}]
  def metrics, do: @metrics

  @doc """
  Aggregates a revision's round outputs by metric median.

  A metric is emitted only when every round supplied it. This prevents a partial
  round from silently changing the sample of observations used by the gate.
  """
  @spec aggregate_runs([map()]) :: map()
  def aggregate_runs(runs) when is_list(runs) do
    scenarios =
      runs
      |> Enum.flat_map(&Map.keys(Map.get(&1, "scenarios", %{})))
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "run_count" => length(runs),
      "scenarios" => Map.new(scenarios, &{&1, aggregate_scenario(runs, &1)})
    }
  end

  @doc """
  Compares aggregated HEAD and base metrics against relative and absolute bounds.

  Relative p50 breaches are merge-blocking. Relative p99 remains advisory until
  the benchmark collects enough within-run samples to support a stable p99.
  Absolute sanity bounds remain blocking for both metrics.
  """
  @spec compare(map(), map() | nil, map()) :: %{blocking: [map()], advisory: [map()]}
  def compare(head, base, budgets) do
    head_scenarios = Map.get(head, "scenarios", %{})

    scenarios =
      head_scenarios
      |> Map.keys()
      |> Kernel.++(base_scenario_names(base))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce(scenarios, %{blocking: [], advisory: []}, fn scenario, result ->
      head_stats = Map.get(head_scenarios, scenario, %{})
      base_stats = scenario_stats(base, scenario)
      sanity = sanity_budget(budgets, scenario)

      Enum.reduce(@metrics, result, fn {key, label, pct_key}, metric_result ->
        relative =
          relative_breaches(
            scenario,
            label,
            Map.get(head_stats, key),
            base_stats,
            key,
            relative_pct(budgets, pct_key)
          )

        sanity_breaches =
          check_sanity(scenario, label, Map.get(head_stats, key), Map.get(sanity, key))

        metric_result
        |> add_relative(relative, label, budgets)
        |> add_blocking(sanity_breaches)
      end)
    end)
  end

  @spec median([number()]) :: number() | nil
  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  defp aggregate_scenario(runs, scenario) do
    Map.new(@metrics, fn {key, _label, _pct_key} ->
      values =
        Enum.map(runs, fn run ->
          run
          |> Map.get("scenarios", %{})
          |> Map.get(scenario, %{})
          |> Map.get(key)
        end)

      case Enum.all?(values, &is_number/1) do
        true -> {key, median(values)}
        false -> {key, nil}
      end
    end)
  end

  defp base_scenario_names(nil), do: []
  defp base_scenario_names(base), do: base |> Map.get("scenarios", %{}) |> Map.keys()

  defp scenario_stats(nil, _scenario), do: nil

  defp scenario_stats(base, scenario) do
    base
    |> Map.get("scenarios", %{})
    |> Map.get(scenario)
  end

  defp relative_pct(budgets, pct_key) do
    budgets
    |> Map.get("relative", %{})
    |> Map.get(pct_key)
  end

  defp sanity_budget(budgets, scenario) do
    budgets
    |> Map.get("absolute_sanity", %{})
    |> Map.get("scenarios", %{})
    |> Map.get(scenario, %{})
  end

  defp relative_breaches(_scenario, _label, _head_us, nil, _key, _pct), do: []

  defp relative_breaches(scenario, label, nil, _base_stats, _key, _pct) do
    [%{kind: :relative, scenario: scenario, field: label, error: "no head measurement found"}]
  end

  defp relative_breaches(scenario, label, _head_us, _base_stats, _key, nil) do
    [
      %{
        kind: :relative,
        scenario: scenario,
        field: label,
        error: "no relative tolerance configured"
      }
    ]
  end

  defp relative_breaches(scenario, label, head_us, base_stats, key, pct) do
    case Map.get(base_stats, key) do
      base_us when is_number(base_us) ->
        allowed = base_us * (1 + pct / 100)

        if head_us > allowed do
          [
            %{
              kind: :relative,
              scenario: scenario,
              field: label,
              head: head_us,
              base: base_us,
              tolerance_pct: pct,
              allowed: round(allowed),
              over_pct: pct_over(head_us, allowed)
            }
          ]
        else
          []
        end

      _ ->
        [%{kind: :relative, scenario: scenario, field: label, error: "no base measurement found"}]
    end
  end

  defp check_sanity(_scenario, _label, _head_us, nil), do: []

  defp check_sanity(scenario, label, nil, _bound) do
    [%{kind: :sanity, scenario: scenario, field: label, error: "no head measurement found"}]
  end

  defp check_sanity(scenario, label, head_us, bound) when head_us > bound do
    [
      %{
        kind: :sanity,
        scenario: scenario,
        field: label,
        head: head_us,
        bound: bound,
        over_pct: pct_over(head_us, bound)
      }
    ]
  end

  defp check_sanity(_scenario, _label, _head_us, _bound), do: []

  defp add_relative(result, breaches, label, budgets) do
    cond do
      relative_gate?(budgets, label) -> add_blocking(result, breaches)
      relative_advisory?(budgets, label) -> %{result | advisory: result.advisory ++ breaches}
      true -> add_blocking(result, breaches)
    end
  end

  defp add_blocking(result, breaches), do: %{result | blocking: result.blocking ++ breaches}

  defp relative_gate?(budgets, label) do
    label in (get_in(budgets, ["relative", "gated_metrics"]) || [])
  end

  defp relative_advisory?(budgets, label) do
    label in (get_in(budgets, ["relative", "advisory_metrics"]) || [])
  end

  defp pct_over(measured, limit), do: round((measured - limit) / limit * 100)
end
