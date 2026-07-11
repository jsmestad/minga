Code.require_file("../../bench/latency_comparison.exs", __DIR__)

defmodule Minga.Bench.LatencyComparisonTest do
  use ExUnit.Case, async: true

  alias Minga.Bench.LatencyComparison

  test "aggregates every round-level scenario metric by median" do
    aggregate =
      LatencyComparison.aggregate_runs([
        run(100, 300),
        run(1_000, 3_000),
        run(110, 310),
        run(120, 320),
        run(130, 330)
      ])

    assert aggregate["run_count"] == 5
    assert aggregate["scenarios"]["small_frame"]["p50_us"] == 120
    assert aggregate["scenarios"]["small_frame"]["p99_us"] == 320
  end

  test "does not aggregate a metric when a round omitted it" do
    incomplete = put_in(run(100, 300), ["scenarios", "small_frame", "p99_us"], nil)

    aggregate = LatencyComparison.aggregate_runs([run(110, 310), incomplete])

    assert aggregate["scenarios"]["small_frame"]["p50_us"] == 105.0
    assert aggregate["scenarios"]["small_frame"]["p99_us"] == nil
  end

  test "makes relative p50 blocking and relative p99 advisory" do
    result =
      LatencyComparison.compare(
        aggregate(111, 130),
        aggregate(100, 100),
        budgets(absolute_p50: 1_000, absolute_p99: 1_000)
      )

    assert [%{kind: :relative, field: "p50", scenario: "small_frame"}] = result.blocking
    assert [%{kind: :relative, field: "p99", scenario: "small_frame"}] = result.advisory
  end

  test "blocks when HEAD omits a scenario measured by base" do
    base =
      aggregate(100, 100)
      |> put_in(["scenarios", "missing_frame"], %{"p50_us" => 90, "p99_us" => 180})

    result =
      LatencyComparison.compare(
        aggregate(100, 100),
        base,
        budgets(absolute_p50: 1_000, absolute_p99: 1_000)
      )

    assert Enum.any?(result.blocking, fn breach ->
             breach.scenario == "missing_frame" and breach.field == "p50" and
               breach.error == "no head measurement found"
           end)
  end

  test "keeps absolute p99 sanity breaches blocking" do
    result =
      LatencyComparison.compare(
        aggregate(100, 500),
        aggregate(100, 100),
        budgets(absolute_p50: 1_000, absolute_p99: 400)
      )

    assert [%{kind: :sanity, field: "p99", scenario: "small_frame"}] = result.blocking
    assert [%{kind: :relative, field: "p99", scenario: "small_frame"}] = result.advisory
  end

  defp run(p50, p99) do
    %{"scenarios" => %{"small_frame" => %{"p50_us" => p50, "p99_us" => p99}}}
  end

  defp aggregate(p50, p99) do
    %{"scenarios" => %{"small_frame" => %{"p50_us" => p50, "p99_us" => p99}}}
  end

  defp budgets(opts) do
    %{
      "relative" => %{
        "p50_pct" => 10,
        "p99_pct" => 20,
        "gated_metrics" => ["p50"],
        "advisory_metrics" => ["p99"]
      },
      "absolute_sanity" => %{
        "scenarios" => %{
          "small_frame" => %{
            "p50_us" => Keyword.fetch!(opts, :absolute_p50),
            "p99_us" => Keyword.fetch!(opts, :absolute_p99)
          }
        }
      }
    }
  end
end
