defmodule MingaAgent.Tools.LspDiagnostics do
  @moduledoc """
  Agent tool that returns current LSP diagnostics for a file.

  Reads diagnostics directly from the `Minga.Diagnostics` ETS table
  (no GenServer call needed). This is the fastest possible path: the
  agent gets compiler-verified errors and warnings in microseconds
  instead of running `mix compile` (5-30 seconds).

  Part of epic #1241. See #1242.
  """

  alias MingaAgent.Tools.LspBridge
  alias Minga.Diagnostics

  @doc """
  Returns formatted diagnostics for the given file path.

  Output is structured text showing severity, line, column, message,
  and source for each diagnostic. Returns "No diagnostics" when the
  file is clean.
  """
  @spec execute(String.t(), keyword()) :: {:ok, String.t()}
  def execute(path, opts \\ []) when is_binary(path) do
    abs_path = Path.expand(path)
    lookup = LspBridge.document_for_path(abs_path)
    shown = LspBridge.display_path(abs_path, Keyword.get(opts, :root))

    case lookup |> diagnostics_uri(abs_path) |> Diagnostics.for_uri() do
      [] -> {:ok, no_diagnostics(shown, lookup)}
      diagnostics -> {:ok, format_diagnostics(shown, diagnostics)}
    end
  end

  # An open document's diagnostics are published under the URI its server
  # opened it with, which can name a symlink. A file that is not open is
  # known by its own path.
  @spec diagnostics_uri(LspBridge.document_result(), String.t()) :: String.t()
  defp diagnostics_uri({:ok, %{uri: uri}}, _abs_path), do: uri
  defp diagnostics_uri({:error, _reason}, abs_path), do: LspBridge.path_to_uri(abs_path)

  @spec no_diagnostics(String.t(), LspBridge.document_result()) :: String.t()
  defp no_diagnostics(path, {:ok, _document}),
    do: "#{path}: No diagnostics. File is clean."

  defp no_diagnostics(path, {:error, reason}),
    do: "#{path}: No diagnostics available. #{reason}"

  # ── Formatting ─────────────────────────────────────────────────────────────

  @spec format_diagnostics(String.t(), [Diagnostics.Diagnostic.t()]) :: String.t()
  defp format_diagnostics(path, diagnostics) do
    counts = Diagnostics.severity_counts(diagnostics)
    summary = format_counts(counts)
    header = "#{path}: #{Enum.count(diagnostics)} diagnostics (#{summary})"

    details =
      Enum.map(diagnostics, fn diag ->
        source_str = if diag.source, do: " (source: #{diag.source})", else: ""

        "  #{diag.severity} line #{diag.range.start_line + 1}:#{diag.range.start_col} — #{diag.message}#{source_str}"
      end)

    Enum.join([header | details], "\n")
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
end
