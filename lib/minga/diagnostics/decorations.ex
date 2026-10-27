defmodule Minga.Diagnostics.Decorations do
  @moduledoc """
  Converts LSP diagnostics into buffer highlight range decorations.

  Each diagnostic becomes an underlined highlight range on the buffer,
  with the underline color determined by the diagnostic severity:
  - `:error` — red underline
  - `:warning` — yellow/orange underline
  - `:info` — blue underline
  - `:hint` — gray underline

  The decorations use group `:diagnostics` so they can be cleared and
  re-applied without affecting other decoration consumers (search,
  agent chat, etc.).

  ## Integration

  Called by the Editor when it receives a `:diagnostics_updated` event
  via `Minga.Events`. The Editor finds the buffer for the URI, fetches the current
  diagnostics, and calls `apply/3` to update the decorations.
  """

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic

  @diagnostic_group :diagnostics
  @severities [:error, :warning, :info, :hint]

  @typep line_cache :: %{non_neg_integer() => String.t()}
  @typep line_run :: {first :: non_neg_integer(), count :: pos_integer()}
  @typep severity_opts :: %{Diagnostic.severity() => keyword()}
  @typep highlight :: {Diagnostic.position(), Diagnostic.position(), Diagnostic.severity()}

  @doc """
  Applies diagnostic decorations to a buffer.

  Clears existing diagnostic decorations (group `:diagnostics`), then
  creates a highlight range for each diagnostic using the severity-appropriate
  underline color from the theme's gutter colors.

  The `gutter_colors` parameter provides the severity → color mapping
  from the current theme.

  Endpoint source lines are read with one `Buffer.lines/3` call per run of consecutive requested lines, and ranges, styles, and priorities are computed before the buffer batch, so the buffer process only installs them.
  """
  @spec apply(pid(), String.t(), MingaEditor.UI.Theme.Gutter.t(), GenServer.server()) :: :ok
  def apply(buf_pid, uri, gutter_colors, diag_server \\ Diagnostics)
      when is_pid(buf_pid) and is_binary(uri) do
    diagnostics = Diagnostics.for_uri(diag_server, uri)
    highlights = highlights(diagnostics, line_cache(buf_pid, diagnostics))
    opts_by_severity = highlight_opts(highlights, gutter_colors)

    Buffer.batch_decorations(buf_pid, fn decs ->
      decs
      |> Decorations.remove_group(@diagnostic_group)
      |> add_highlights(highlights, opts_by_severity)
    end)
  end

  @doc """
  Clears all diagnostic decorations from a buffer.
  """
  @spec clear(pid()) :: :ok
  def clear(buf_pid) when is_pid(buf_pid) do
    Buffer.batch_decorations(buf_pid, fn decs ->
      Decorations.remove_group(decs, @diagnostic_group)
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────

  # The batch holds one style per severity, shared by every installed range.
  @spec add_highlights(Decorations.t(), [highlight()], severity_opts()) :: Decorations.t()
  defp add_highlights(decs, highlights, opts_by_severity) do
    Enum.reduce(highlights, decs, fn {start_pos, end_pos, severity}, acc ->
      opts = Map.fetch!(opts_by_severity, severity)
      {_id, acc} = Decorations.add_highlight(acc, start_pos, end_pos, opts)
      acc
    end)
  end

  @spec highlights([Diagnostic.t()], line_cache()) :: [highlight()]
  defp highlights(diagnostics, line_cache) do
    diagnostics
    |> Enum.reduce([], &prepend_highlight(&1, &2, line_cache))
    |> Enum.reverse()
  end

  @spec prepend_highlight(Diagnostic.t(), [highlight()], line_cache()) :: [highlight()]
  defp prepend_highlight(%Diagnostic{} = diag, highlights, line_cache) do
    start_pos = Diagnostic.start_position(diag, Map.get(line_cache, diag.range.start_line, ""))
    end_pos = Diagnostic.end_position(diag, Map.get(line_cache, diag.range.end_line, ""))

    # Skip zero-width ranges (some LSP servers report point diagnostics)
    if start_pos == end_pos do
      highlights
    else
      [{start_pos, end_pos, diag.severity} | highlights]
    end
  end

  @spec highlight_opts([highlight()], MingaEditor.UI.Theme.Gutter.t()) :: severity_opts()
  defp highlight_opts([], _gutter_colors), do: %{}

  defp highlight_opts(_highlights, gutter_colors) do
    Map.new(@severities, fn severity ->
      style = Face.new(underline: true, underline_color: severity_color(severity, gutter_colors))
      {severity, [style: style, priority: severity_priority(severity), group: @diagnostic_group]}
    end)
  end

  @spec line_cache(pid(), [Diagnostic.t()]) :: line_cache()
  defp line_cache(buf_pid, diagnostics) do
    diagnostics
    |> Enum.flat_map(fn diag -> [diag.range.start_line, diag.range.end_line] end)
    |> Enum.sort()
    |> Enum.dedup()
    |> line_runs()
    |> Enum.reduce([], fn {first, count}, numbered ->
      number_lines(Buffer.lines(buf_pid, first, count), first, numbered)
    end)
    |> Map.new()
  end

  # Group sorted, unique endpoint lines into maximal consecutive runs.
  @spec line_runs([non_neg_integer()]) :: [line_run()]
  defp line_runs([]), do: []
  defp line_runs([line | lines]), do: line_runs(lines, line, 1, [])

  @spec line_runs([non_neg_integer()], non_neg_integer(), pos_integer(), [line_run()]) ::
          [line_run()]
  defp line_runs([line | lines], first, count, runs) when line == first + count,
    do: line_runs(lines, first, count + 1, runs)

  defp line_runs([line | lines], first, count, runs),
    do: line_runs(lines, line, 1, [{first, count} | runs])

  defp line_runs([], first, count, runs), do: [{first, count} | runs]

  # Lines past the buffer end are absent from the slice and fall back to "" at lookup.
  @spec number_lines([String.t()], non_neg_integer(), [{non_neg_integer(), String.t()}]) ::
          [{non_neg_integer(), String.t()}]
  defp number_lines([], _line, numbered), do: numbered

  defp number_lines([text | texts], line, numbered),
    do: number_lines(texts, line + 1, [{line, text} | numbered])

  @spec severity_color(Diagnostic.severity(), MingaEditor.UI.Theme.Gutter.t()) ::
          non_neg_integer()
  defp severity_color(:error, colors), do: colors.error_fg
  defp severity_color(:warning, colors), do: colors.warning_fg
  defp severity_color(:info, colors), do: colors.info_fg
  defp severity_color(:hint, colors), do: colors.hint_fg

  @spec severity_priority(Diagnostic.severity()) :: integer()
  defp severity_priority(:error), do: 40
  defp severity_priority(:warning), do: 30
  defp severity_priority(:info), do: 20
  defp severity_priority(:hint), do: 10
end
