defmodule Minga.Bench.CheckLatencyBudgets do
  @moduledoc """
  Enforces keystroke latency budgets with a same-runner A/B comparison.

  The gate is RELATIVE, not absolute. On `pull_request` CI runs the workflow
  benches the PR's merge-base and the PR HEAD on the same runner, then runs this
  script with `--base <base.json>`. For every scenario/metric we require:

      head <= base * (1 + tolerance)

  with tolerances from `bench/latency_budgets.json` (`relative.p50_pct`,
  `relative.p99_pct`). This cancels runner speed: GitHub hosted runners vary
  run-to-run, so absolute ceilings calibrated on one machine can never be both
  tight and stable.

  Absolute ceilings survive only as loose catastrophic sanity bounds
  (`absolute_sanity.scenarios`), recalibrated generously for runner reality.
  They are NOT the gate; they catch a ~2x regression even when the base bench is
  unavailable.

  Modes:

    * `--base <path>` given: relative gate (per scenario/metric) AND absolute
      sanity. Either breach class exits 1 with a per-metric report.
    * no `--base`: absolute sanity only, with a loud warning that the relative
      gate was skipped. Used on push-to-main (record/trend) runs and as the
      fallback when the base bench could not run for infrastructure reasons.

  Run with:

      MIX_ENV=test mix run bench/check_latency_budgets.exs [--base /path/to/base.json]
  """

  @baseline_path Path.join([__DIR__, "baselines", "keystroke_latency.json"])
  @budgets_path Path.join([__DIR__, "latency_budgets.json"])

  @metrics [{"p50_us", "p50", "p50_pct"}, {"p99_us", "p99", "p99_pct"}]

  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    head = load_json!(@baseline_path)
    budgets = load_json!(@budgets_path)
    base = load_base(parse_base_path(argv))

    breaches = check(head, base, budgets)

    report(breaches, base)
  end

  @spec parse_base_path([String.t()]) :: String.t() | nil
  defp parse_base_path(["--base", path | _rest]), do: path
  defp parse_base_path([_other | rest]), do: parse_base_path(rest)
  defp parse_base_path([]), do: nil

  @spec load_base(String.t() | nil) :: map() | nil
  defp load_base(nil), do: nil
  defp load_base(path), do: load_json!(path)

  # ── Checking ─────────────────────────────────────────────────────────────────

  @spec check(map(), map() | nil, map()) :: [map()]
  defp check(head, base, budgets) do
    head_scenarios = Map.get(head, "scenarios", %{})

    Enum.flat_map(head_scenarios, fn {scenario, head_stats} ->
      sanity = sanity_budget(budgets, scenario)
      base_stats = base_scenario(base, scenario)

      Enum.flat_map(@metrics, fn {key, label, pct_key} ->
        head_us = Map.get(head_stats, key)

        check_relative(scenario, label, head_us, base_stats, key, relative_pct(budgets, pct_key)) ++
          check_sanity(scenario, label, head_us, Map.get(sanity, key))
      end)
    end)
  end

  @spec relative_pct(map(), String.t()) :: number() | nil
  defp relative_pct(budgets, pct_key) do
    budgets
    |> Map.get("relative", %{})
    |> Map.get(pct_key)
  end

  @spec sanity_budget(map(), String.t()) :: map()
  defp sanity_budget(budgets, scenario) do
    budgets
    |> Map.get("absolute_sanity", %{})
    |> Map.get("scenarios", %{})
    |> Map.get(scenario, %{})
  end

  @spec base_scenario(map() | nil, String.t()) :: map() | nil
  defp base_scenario(nil, _scenario), do: nil

  defp base_scenario(base, scenario) do
    base
    |> Map.get("scenarios", %{})
    |> Map.get(scenario)
  end

  # Relative gate only applies when we have a base bench to compare against.
  @spec check_relative(
          String.t(),
          String.t(),
          number() | nil,
          map() | nil,
          String.t(),
          number() | nil
        ) ::
          [map()]
  defp check_relative(_scenario, _label, _head_us, nil, _key, _pct), do: []

  defp check_relative(scenario, label, nil, _base_stats, _key, _pct),
    do: [%{kind: :relative, scenario: scenario, field: label, error: "no head measurement found"}]

  defp check_relative(scenario, label, _head_us, _base_stats, _key, nil),
    do: [
      %{
        kind: :relative,
        scenario: scenario,
        field: label,
        error: "no relative tolerance configured"
      }
    ]

  defp check_relative(scenario, label, head_us, base_stats, key, pct) do
    eval_relative(scenario, label, head_us, Map.get(base_stats, key), pct)
  end

  @spec eval_relative(String.t(), String.t(), number(), number() | nil, number()) :: [map()]
  defp eval_relative(scenario, label, _head_us, nil, _pct),
    do: [%{kind: :relative, scenario: scenario, field: label, error: "no base measurement found"}]

  defp eval_relative(scenario, label, head_us, base_us, pct) do
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
          allowed: round_us(allowed),
          over_pct: pct_over(head_us, allowed)
        }
      ]
    else
      []
    end
  end

  @spec check_sanity(String.t(), String.t(), number() | nil, number() | nil) :: [map()]
  defp check_sanity(_scenario, _label, _head_us, nil), do: []

  defp check_sanity(scenario, label, nil, _bound),
    do: [%{kind: :sanity, scenario: scenario, field: label, error: "no head measurement found"}]

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

  # ── Reporting ────────────────────────────────────────────────────────────────

  @spec report([map()], map() | nil) :: :ok | no_return()
  defp report(breaches, base) do
    print_mode(base)

    if Enum.empty?(breaches) do
      IO.puts("✓ All latency budgets within limits")
      :ok
    else
      IO.puts("\n✗ Latency budget breaches detected:\n")
      print_breaches(breaches)
      System.halt(1)
    end
  end

  @spec print_mode(map() | nil) :: :ok
  defp print_mode(nil) do
    IO.puts(:stderr, "WARNING: no --base provided; the relative same-runner gate is SKIPPED.")

    IO.puts(
      :stderr,
      "WARNING: enforcing ABSOLUTE SANITY bounds only (catastrophic-regression backstop, not the real gate)."
    )

    :ok
  end

  defp print_mode(_base) do
    IO.puts("Relative same-runner gate active (head vs base) + absolute sanity backstop.")
    :ok
  end

  @spec print_breaches([map()]) :: :ok
  defp print_breaches(breaches) do
    Enum.each(breaches, &print_breach/1)
    :ok
  end

  @spec print_breach(map()) :: :ok
  defp print_breach(%{error: error, kind: kind, scenario: scenario, field: field}) do
    IO.puts("  [#{kind}] #{scenario}/#{field}: #{error}")
  end

  defp print_breach(%{
         kind: :relative,
         scenario: scenario,
         field: field,
         head: head,
         base: base,
         tolerance_pct: tol,
         allowed: allowed,
         over_pct: over
       }) do
    IO.puts(
      "  [relative] #{scenario}/#{field}: head #{head}µs vs base #{base}µs " <>
        "(allowed #{allowed}µs at +#{tol}%, +#{over}% over)"
    )
  end

  defp print_breach(%{
         kind: :sanity,
         scenario: scenario,
         field: field,
         head: head,
         bound: bound,
         over_pct: over
       }) do
    IO.puts(
      "  [sanity] #{scenario}/#{field}: head #{head}µs exceeds sanity bound #{bound}µs (+#{over}% over)"
    )
  end

  # ── Math / IO helpers ────────────────────────────────────────────────────────

  @spec pct_over(number(), number()) :: integer()
  defp pct_over(measured, limit), do: round((measured - limit) / limit * 100)

  @spec round_us(number()) :: integer()
  defp round_us(value), do: round(value)

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

Minga.Bench.CheckLatencyBudgets.run(System.argv())
