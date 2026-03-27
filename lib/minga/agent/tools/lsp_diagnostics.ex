defmodule Minga.Agent.Tools.LspDiagnostics do
  @moduledoc """
  Agent tool that returns current LSP diagnostics for a file.

  Reads diagnostics directly from the `Minga.Diagnostics` ETS table
  (no GenServer call needed). This is the fastest possible path: the
  agent gets compiler-verified errors and warnings in microseconds
  instead of running `mix compile` (5-30 seconds).

  Part of epic #1241. See #1242.
  """

  alias Minga.Agent.Tools.LspBridge
  alias Minga.Diagnostics

  @doc """
  Returns formatted diagnostics for the given file path.

  Output is structured text showing severity, line, column, message,
  and source for each diagnostic. Returns "No diagnostics" when the
  file is clean.
  """
  @spec execute(String.t()) :: {:ok, String.t()}
  def execute(path) when is_binary(path) do
    abs_path = Path.expand(path)
    uri = LspBridge.path_to_uri(abs_path)
    diags = Diagnostics.for_uri(uri)

    case diags do
      [] ->
        # Check if we even have an LSP client for context
        case LspBridge.client_for_path(abs_path) do
          {:ok, _} ->
            {:ok, "#{relative_path(path)}: No diagnostics. File is clean."}

          {:error, reason} ->
            {:ok, "#{relative_path(path)}: No diagnostics available. #{reason}"}
        end

      diagnostics ->
        {:ok, format_diagnostics(path, diagnostics)}
    end
  end

  # ── Formatting ─────────────────────────────────────────────────────────────

  @spec format_diagnostics(String.t(), [Diagnostics.Diagnostic.t()]) :: String.t()
  defp format_diagnostics(path, diagnostics) do
    counts = count_by_severity(diagnostics)
    summary = format_counts(counts)
    rel = relative_path(path)
    header = "#{rel}: #{length(diagnostics)} diagnostics (#{summary})"

    details =
      Enum.map(diagnostics, fn diag ->
        source_str = if diag.source, do: " (source: #{diag.source})", else: ""

        "  #{diag.severity} line #{diag.range.start_line + 1}:#{diag.range.start_col} — #{diag.message}#{source_str}"
      end)

    Enum.join([header | details], "\n")
  end

  @spec count_by_severity([Diagnostics.Diagnostic.t()]) :: %{atom() => non_neg_integer()}
  defp count_by_severity(diagnostics) do
    Enum.reduce(diagnostics, %{error: 0, warning: 0, info: 0, hint: 0}, fn diag, acc ->
      Map.update!(acc, diag.severity, &(&1 + 1))
    end)
  end

  @spec format_counts(%{atom() => non_neg_integer()}) :: String.t()
  defp format_counts(counts) do
    parts =
      [:error, :warning, :info, :hint]
      |> Enum.filter(fn sev -> Map.get(counts, sev, 0) > 0 end)
      |> Enum.map(fn sev -> "#{Map.get(counts, sev)} #{sev}" end)

    case parts do
      [] -> "clean"
      _ -> Enum.join(parts, ", ")
    end
  end

  @spec relative_path(String.t()) :: String.t()
  defp relative_path(path) do
    cwd = File.cwd!()
    expanded = Path.expand(path)

    if String.starts_with?(expanded, cwd <> "/") do
      Path.relative_to(expanded, cwd)
    else
      path
    end
  end
end
