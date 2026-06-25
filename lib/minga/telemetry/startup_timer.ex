defmodule Minga.Telemetry.StartupTimer do
  @moduledoc """
  Measures wall-clock time for each phase of the application startup path.

  Writes a summary table to stderr when the editor signals ready, so the
  output appears in Console.app (macOS GUI) or the terminal (TUI dev mode).

  ## Usage

  Called from `Minga.Application.start/2` and key supervisor init callbacks.
  Each call to `mark/1` records a monotonic timestamp under the given label.
  When the editor handles the `:ready` signal, `report/0` prints the
  cumulative and per-phase durations, then clears state.

  Zero overhead when not measured: all state is process-dictionary-free,
  stored in a single :persistent_term that is cleaned up after report.
  """

  @key {__MODULE__, :marks}

  @spec start() :: :ok
  def start do
    :persistent_term.put(@key, [{:app_start, System.monotonic_time(:microsecond)}])
    :ok
  end

  @spec mark(atom()) :: :ok
  def mark(label) when is_atom(label) do
    case safe_get() do
      nil -> :ok
      marks -> :persistent_term.put(@key, [{label, System.monotonic_time(:microsecond)} | marks])
    end

    :ok
  end

  @spec report() :: :ok
  def report do
    case safe_get() do
      nil ->
        :ok

      marks ->
        :persistent_term.erase(@key)
        print_report(Enum.reverse(marks))
    end
  end

  @spec schedule_fallback_report(non_neg_integer()) :: :ok
  def schedule_fallback_report(delay_ms \\ 3000) do
    spawn(fn ->
      Process.sleep(delay_ms)
      report()
    end)

    :ok
  end

  @spec timed_child_spec(atom(), Supervisor.child_spec() | module() | {module(), term()}) ::
          Supervisor.child_spec()
  def timed_child_spec(label, child) do
    spec = Supervisor.child_spec(child, [])
    original_start = spec.start

    spec
    |> Map.put(:start, {__MODULE__, :timed_start, [label, original_start]})
  end

  @doc false
  def timed_start(label, {mod, fun, args}) do
    mark(label)
    result = apply(mod, fun, args)
    mark(:"#{label}_done")
    result
  end

  defp safe_get do
    :persistent_term.get(@key, nil)
  end

  defp print_report([]) do
    :ok
  end

  defp print_report([{_first_label, origin} | _] = marks) do
    lines =
      marks
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{_from_label, from_time}, {to_label, to_time}] ->
        delta_ms = (to_time - from_time) / 1000.0
        cumulative_ms = (to_time - origin) / 1000.0

        pad_label = String.pad_trailing(to_string(to_label), 30)
        pad_delta = String.pad_leading(:erlang.float_to_binary(delta_ms, decimals: 1), 8)
        pad_cumul = String.pad_leading(:erlang.float_to_binary(cumulative_ms, decimals: 1), 8)

        "  #{pad_label} #{pad_delta}ms  (#{pad_cumul}ms total)"
      end)

    {_last_label, last_time} = List.last(marks)
    total_ms = (last_time - origin) / 1000.0

    output =
      [
        "[startup-timer] ─────────────────────────────────────────────",
        "  Phase                            Delta      Cumulative" | lines
      ] ++
        [
          "  ──────────────────────────────────────────────────────────",
          "  TOTAL                          #{String.pad_leading(:erlang.float_to_binary(total_ms, decimals: 1), 8)}ms",
          ""
        ]

    report_text = Enum.join(output, "\n")
    report_path = Path.join(System.tmp_dir!(), "minga-startup-timer.txt")
    File.write!(report_path, report_text <> "\n")
    IO.puts(:stderr, report_text)
  rescue
    _ -> :ok
  end
end
