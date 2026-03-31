defmodule MingaAgent.Tools.DiagnosticFeedback do
  @moduledoc """
  Waits for LSP diagnostics to settle after a file edit and returns a summary.

  After the agent edits a file, this module subscribes to `:diagnostics_updated`
  events, waits for the LSP server to finish processing (quiet period with no
  new events), then reads the final diagnostics from ETS.

  The settle algorithm:
  1. Subscribe to `:diagnostics_updated` events
  2. Wait for events matching the file's URI
  3. After each event, reset the quiet timer
  4. When the quiet period elapses (or the deadline hits), read final diagnostics
  5. Unsubscribe and return the summary

  Without buffer-aware agents, the chain is:
  `File.write` -> file watcher -> buffer reloads -> SyncServer.did_change -> LSP processes -> diagnostics published

  This takes 1-3 seconds. The 5-second default timeout accommodates this.

  Part of epic #1241. See #1245.
  """

  alias MingaAgent.Tools.LspBridge
  alias Minga.Buffer
  alias Minga.Diagnostics
  alias Minga.Events
  alias Minga.LSP.SyncServer

  @default_timeout 5_000
  @default_quiet_period 500

  @typedoc "Options for `await/2`."
  @type await_opts :: [timeout: non_neg_integer(), quiet_period: non_neg_integer()]

  @doc """
  Waits for diagnostics to settle for the given file path, then returns a summary.

  Returns one of:
  - `{:ok, summary}` with diagnostic details
  - `{:skip, reason}` when LSP is unavailable (not an error, just context)

  The summary is formatted for appending to a tool response.
  """
  @spec await(String.t(), await_opts()) :: {:ok, String.t()} | {:skip, String.t()}
  def await(file_path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    quiet_ms = Keyword.get(opts, :quiet_period, @default_quiet_period)
    abs_path = Path.expand(file_path)

    case has_lsp_client?(abs_path) do
      true ->
        uri = LspBridge.path_to_uri(abs_path)
        summary = do_await(uri, timeout, quiet_ms)
        {:ok, summary}

      false ->
        {:skip, "No LSP diagnostics available for this file."}
    end
  end

  @doc """
  Formats a diagnostic feedback result for appending to a tool response.

  Combines the tool's original success message with diagnostic context.
  """
  @spec append_to_result(String.t(), {:ok, String.t()} | {:skip, String.t()}) :: String.t()
  def append_to_result(base_message, {:ok, summary}) do
    "#{base_message}\n\n#{summary}"
  end

  def append_to_result(base_message, {:skip, reason}) do
    "#{base_message}\n\n(#{reason})"
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec has_lsp_client?(String.t()) :: boolean()
  defp has_lsp_client?(abs_path) do
    case Buffer.Server.pid_for_path(abs_path) do
      {:ok, buf_pid} -> SyncServer.clients_for_buffer(buf_pid) != []
      :not_found -> false
    end
  rescue
    _ -> false
  end

  @spec do_await(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  defp do_await(uri, timeout, quiet_ms) do
    Events.subscribe(:diagnostics_updated)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      result = wait_for_quiet(uri, deadline, quiet_ms)
      format_settled_diagnostics(uri, result)
    after
      Events.unsubscribe(:diagnostics_updated)
    end
  end

  @spec wait_for_quiet(String.t(), integer(), non_neg_integer()) :: :settled | :timeout
  defp wait_for_quiet(uri, deadline, quiet_ms) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      wait_time = min(quiet_ms, remaining)

      receive do
        {:minga_event, :diagnostics_updated, %{uri: ^uri}} ->
          # Got an update for our file; reset the quiet timer
          wait_for_quiet(uri, deadline, quiet_ms)

        {:minga_event, :diagnostics_updated, _} ->
          # Update for a different file; keep waiting
          wait_for_quiet(uri, deadline, quiet_ms)
      after
        wait_time ->
          # Quiet period elapsed with no events
          :settled
      end
    end
  end

  @spec format_settled_diagnostics(String.t(), :settled | :timeout) :: String.t()
  defp format_settled_diagnostics(uri, status) do
    diags = Diagnostics.for_uri(uri)
    timeout_note = if status == :timeout, do: " (diagnostics may still be updating)", else: ""

    case diags do
      [] ->
        "Diagnostics: clean#{timeout_note}"

      diagnostics ->
        counts = count_by_severity(diagnostics)
        summary = format_counts(counts)
        header = "Diagnostics: #{length(diagnostics)} issues (#{summary})#{timeout_note}"

        details =
          diagnostics
          |> Enum.take(10)
          |> Enum.map(fn diag ->
            "  #{diag.severity} line #{diag.range.start_line + 1}: #{diag.message}"
          end)

        remaining = length(diagnostics) - 10

        details =
          if remaining > 0 do
            details ++ ["  ... and #{remaining} more"]
          else
            details
          end

        Enum.join([header | details], "\n")
    end
  end

  @spec count_by_severity([Diagnostics.Diagnostic.t()]) :: %{atom() => non_neg_integer()}
  defp count_by_severity(diagnostics) do
    Enum.reduce(diagnostics, %{error: 0, warning: 0, info: 0, hint: 0}, fn diag, acc ->
      Map.update!(acc, diag.severity, &(&1 + 1))
    end)
  end

  @spec format_counts(%{atom() => non_neg_integer()}) :: String.t()
  defp format_counts(counts) do
    [:error, :warning, :info, :hint]
    |> Enum.filter(fn sev -> Map.get(counts, sev, 0) > 0 end)
    |> Enum.map_join(", ", fn sev -> "#{Map.get(counts, sev)} #{sev}" end)
  end
end
