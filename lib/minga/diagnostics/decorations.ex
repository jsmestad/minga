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

  Called by the Editor when it receives a `{:diagnostics_changed, uri}`
  message. The Editor finds the buffer for the URI, fetches the current
  diagnostics, and calls `apply/3` to update the decorations.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Server, as: BufferServer
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
  @spec apply(pid(), String.t(), Minga.Theme.Gutter.t(), GenServer.server()) :: :ok
  def apply(buf_pid, uri, gutter_colors, diag_server \\ Diagnostics)
      when is_pid(buf_pid) and is_binary(uri) do
    diagnostics = Diagnostics.for_uri(diag_server, uri)

    BufferServer.batch_decorations(buf_pid, fn decs ->
      decs
      |> Decorations.remove_group(@diagnostic_group)
      |> add_diagnostic_ranges(diagnostics, gutter_colors)
    end)
  end

  @doc """
  Clears all diagnostic decorations from a buffer.
  """
  @spec clear(pid()) :: :ok
  def clear(buf_pid) when is_pid(buf_pid) do
    BufferServer.batch_decorations(buf_pid, fn decs ->
      Decorations.remove_group(decs, @diagnostic_group)
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────

  @spec add_diagnostic_ranges(Decorations.t(), [Diagnostic.t()], Minga.Theme.Gutter.t()) ::
          Decorations.t()
  defp add_diagnostic_ranges(decs, diagnostics, gutter_colors) do
    Enum.reduce(diagnostics, decs, fn diag, acc ->
      add_one(acc, diag, gutter_colors)
    end)
  end

  @spec add_one(Decorations.t(), Diagnostic.t(), Minga.Theme.Gutter.t()) :: Decorations.t()
  defp add_one(decs, %Diagnostic{range: range} = diag, gutter_colors) do
    start_pos = {range.start_line, range.start_col}
    end_pos = {range.end_line, range.end_col}

    # Skip zero-width ranges (some LSP servers report point diagnostics)
    if start_pos == end_pos do
      decs
    else
      color = severity_color(diag.severity, gutter_colors)

      style = [
        underline: true,
        underline_color: color
      ]

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

  @spec severity_color(Diagnostic.severity(), Minga.Theme.Gutter.t()) :: non_neg_integer()
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
