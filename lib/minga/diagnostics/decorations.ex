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

  @doc """
  Applies diagnostic decorations to a buffer.

  Clears existing diagnostic decorations (group `:diagnostics`), then
  creates a highlight range for each diagnostic using the severity-appropriate
  underline color from the theme's gutter colors.

  The `gutter_colors` parameter provides the severity → color mapping
  from the current theme.
  """
  @spec apply(pid(), String.t(), MingaEditor.UI.Theme.Gutter.t(), GenServer.server()) :: :ok
  def apply(buf_pid, uri, gutter_colors, diag_server \\ Diagnostics)
      when is_pid(buf_pid) and is_binary(uri) do
    diagnostics = Diagnostics.for_uri(diag_server, uri)
    line_cache = line_cache(buf_pid, diagnostics)

    Buffer.batch_decorations(buf_pid, fn decs ->
      decs
      |> Decorations.remove_group(@diagnostic_group)
      |> add_diagnostic_ranges(diagnostics, gutter_colors, line_cache)
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

  @spec add_diagnostic_ranges(
          Decorations.t(),
          [Diagnostic.t()],
          MingaEditor.UI.Theme.Gutter.t(),
          %{non_neg_integer() => String.t()}
        ) :: Decorations.t()
  defp add_diagnostic_ranges(decs, diagnostics, gutter_colors, line_cache) do
    Enum.reduce(diagnostics, decs, fn diag, acc ->
      add_one(acc, diag, gutter_colors, line_cache)
    end)
  end

  @spec add_one(
          Decorations.t(),
          Diagnostic.t(),
          MingaEditor.UI.Theme.Gutter.t(),
          %{non_neg_integer() => String.t()}
        ) :: Decorations.t()
  defp add_one(decs, %Diagnostic{} = diag, gutter_colors, line_cache) do
    start_text = Map.get(line_cache, diag.range.start_line, "")
    end_text = Map.get(line_cache, diag.range.end_line, "")
    start_pos = Diagnostic.start_position(diag, start_text)
    end_pos = Diagnostic.end_position(diag, end_text)

    # Skip zero-width ranges (some LSP servers report point diagnostics)
    if start_pos == end_pos do
      decs
    else
      color = severity_color(diag.severity, gutter_colors)

      style =
        Face.new(
          underline: true,
          underline_color: color
        )

      priority = severity_priority(diag.severity)

      {_id, decs} =
        Decorations.add_highlight(decs, start_pos, end_pos,
          style: style,
          priority: priority,
          group: @diagnostic_group
        )

      decs
    end
  end

  @spec line_cache(pid(), [Diagnostic.t()]) :: %{non_neg_integer() => String.t()}
  defp line_cache(buf_pid, diagnostics) do
    diagnostics
    |> Enum.flat_map(fn diag -> [diag.range.start_line, diag.range.end_line] end)
    |> Enum.uniq()
    |> Map.new(fn line -> {line, line_text(buf_pid, line)} end)
  end

  @spec line_text(pid(), non_neg_integer()) :: String.t()
  defp line_text(buf_pid, line) do
    case Buffer.lines(buf_pid, line, 1) do
      [text] -> text
      _ -> ""
    end
  end

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
