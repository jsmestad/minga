Code.require_file("latency_comparison.exs", __DIR__)

defmodule Minga.Bench.CheckLatencyBudgets do
  @moduledoc """
  Enforces keystroke latency budgets from a symmetric same-runner A/B benchmark.

  CI collects repeated base and HEAD rounds in alternating order, then this
  script compares the median round-level metric for each revision. `p50` is the
  strict relative merge gate. `p99` is reported as an advisory comparison until
  a benchmark invocation has enough within-run samples to make a stable p99;
  both metrics retain absolute catastrophic sanity bounds.

  With repeated paths, use:

      MIX_ENV=test mix run bench/check_latency_budgets.exs \
        --base /tmp/base-1.json --base /tmp/base-2.json \
        --head /tmp/head-1.json --head /tmp/head-2.json \
        --comparison-output bench/baselines/keystroke_latency_comparison.json

  Without `--base`, only absolute sanity bounds are enforced. This is used for
  push-to-main trend recording and when a base revision cannot be benchmarked.
  """

  # Loaded from bench/latency_comparison.exs above; it is intentionally a
  # script-local module rather than part of the production application.
  @compile {:no_warn_undefined, Minga.Bench.LatencyComparison}
  alias Minga.Bench.LatencyComparison

  @baseline_path Path.join([__DIR__, "baselines", "keystroke_latency.json"])
  @budgets_path Path.join([__DIR__, "latency_budgets.json"])

  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    options = parse_options(argv)
    head_runs = load_runs(options.head_paths, @baseline_path)
    base_runs = Enum.map(options.base_paths, &load_json!/1)
    budgets = load_json!(@budgets_path)

    head = LatencyComparison.aggregate_runs(head_runs)
    base = aggregate_base(base_runs)
    result = LatencyComparison.compare(head, base, budgets)

    write_comparison(options.comparison_output, base_runs, head_runs, base, head, result)
    report(result, base)
  end

  @spec parse_options([String.t()]) :: %{
          base_paths: [String.t()],
          head_paths: [String.t()],
          comparison_output: String.t() | nil
        }
  defp parse_options(argv),
    do: parse_options(argv, %{base_paths: [], head_paths: [], comparison_output: nil})

  defp parse_options(["--base", path | rest], options),
    do: parse_options(rest, %{options | base_paths: options.base_paths ++ [path]})

  defp parse_options(["--head", path | rest], options),
    do: parse_options(rest, %{options | head_paths: options.head_paths ++ [path]})

  defp parse_options(["--comparison-output", path | rest], options),
    do: parse_options(rest, %{options | comparison_output: path})

  defp parse_options([_other | rest], options), do: parse_options(rest, options)
  defp parse_options([], options), do: options

  defp load_runs([], fallback_path), do: [load_json!(fallback_path)]
  defp load_runs(paths, _fallback_path), do: Enum.map(paths, &load_json!/1)
  defp aggregate_base([]), do: nil
  defp aggregate_base(runs), do: LatencyComparison.aggregate_runs(runs)

  # ── Reporting ────────────────────────────────────────────────────────────────

  defp report(%{blocking: blocking, advisory: advisory}, base) do
    print_mode(base)
    print_advisories(advisory)

    if Enum.empty?(blocking) do
      IO.puts("✓ All blocking latency budgets within limits")
      :ok
    else
      IO.puts("\n✗ Latency budget breaches detected:\n")
      print_breaches(blocking)
      System.halt(1)
    end
  end

  defp print_mode(nil) do
    IO.puts(:stderr, "WARNING: no --base provided; the relative same-runner gate is SKIPPED.")

    IO.puts(
      :stderr,
      "WARNING: enforcing ABSOLUTE SANITY bounds only (catastrophic-regression backstop, not the real gate)."
    )
  end

  defp print_mode(base) do
    IO.puts(
      "Symmetric same-runner A/B gate active: #{base["run_count"]} base and HEAD round(s), median aggregation; p50 required, p99 advisory."
    )
  end

  defp print_advisories([]), do: :ok

  defp print_advisories(advisory) do
    IO.puts("\n! Advisory latency observations (non-blocking):\n")
    print_breaches(advisory)
  end

  defp print_breaches(breaches), do: Enum.each(breaches, &print_breach/1)

  defp print_breach(%{error: error, kind: kind, scenario: scenario, field: field}) do
    IO.puts("  [#{kind}] #{scenario}/#{field}: #{error}")
  end

  defp print_breach(%{
         kind: :relative,
         scenario: scenario,
         field: field,
         head: head,
         base: base,
         tolerance_pct: tolerance,
         allowed: allowed,
         over_pct: over
       }) do
    IO.puts(
      "  [relative] #{scenario}/#{field}: head #{head}µs vs base #{base}µs " <>
        "(allowed #{allowed}µs at +#{tolerance}%, +#{over}% over)"
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

  # ── Comparison artifact ──────────────────────────────────────────────────────

  defp write_comparison(nil, _base_runs, _head_runs, _base, _head, _result), do: :ok

  defp write_comparison(path, base_runs, head_runs, base, head, result) do
    payload = %{
      "schema" => "minga.keystroke_latency.comparison.v1",
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "methodology" => %{
        "round_aggregation" => "median",
        "relative_gate_metrics" => ["p50"],
        "relative_advisory_metrics" => ["p99"]
      },
      "rounds" => %{"base" => base_runs, "head" => head_runs},
      "aggregate" => %{"base" => base, "head" => head},
      "result" => %{
        "blocking_breaches" => Enum.map(result.blocking, &json_breach/1),
        "advisories" => Enum.map(result.advisory, &json_breach/1)
      }
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(payload) <> "\n")
    IO.puts("Wrote comparison artifact: #{path}")
  end

  defp json_breach(breach) do
    breach
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.update("kind", nil, &to_string/1)
  end

  # ── IO helpers ───────────────────────────────────────────────────────────────

  defp load_json!(path) do
    case File.read(path) do
      {:ok, content} -> decode_json!(path, content)
      {:error, :enoent} -> halt("Error: #{path} not found. Run the latency benchmark first.")
      {:error, reason} -> halt("Error reading #{path}: #{inspect(reason)}")
    end
  end

  defp decode_json!(path, content) do
    case JSON.decode(content) do
      {:ok, data} when is_map(data) -> data
      {:ok, other} -> halt("Error: #{path} did not decode to a JSON object: #{inspect(other)}")
      {:error, reason} -> halt("Error parsing #{path}: #{inspect(reason)}")
    end
  end

  defp halt(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

Minga.Bench.CheckLatencyBudgets.run(System.argv())
