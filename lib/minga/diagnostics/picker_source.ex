defmodule Minga.Diagnostics.PickerSource do
  @moduledoc """
  Picker source for listing buffer diagnostics.

  Invoked via `SPC c d` — shows all diagnostics for the current buffer
  with severity, location, and message. Selecting a diagnostic jumps
  the cursor to that position.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Diagnostics
  alias Minga.Editor.DocumentSync

  @impl true
  @spec title() :: String.t()
  def title, do: "Diagnostics"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(%{buf: %{buffer: buf}}) when is_pid(buf) do
    buf
    |> BufferServer.file_path()
    |> candidates_for_path()
  end

  def candidates(_state), do: []

  @spec candidates_for_path(String.t() | nil) :: [Minga.Picker.item()]
  defp candidates_for_path(nil), do: []

  defp candidates_for_path(path) do
    path
    |> DocumentSync.path_to_uri()
    |> Diagnostics.for_uri()
    |> Enum.map(&format_candidate/1)
  end

  @spec format_candidate(Diagnostics.Diagnostic.t()) :: Minga.Picker.item()
  defp format_candidate(diag) do
    icon = severity_icon(diag.severity)
    line = diag.range.start_line + 1
    col = diag.range.start_col + 1
    source_tag = if diag.source, do: " (#{diag.source})", else: ""
    label = "#{icon} #{line}:#{col}  #{diag.message}#{source_tag}"

    {{diag.range.start_line, diag.range.start_col}, label, ""}
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({{line, col}, _label, _desc}, state) do
    case state.buf.buffer do
      nil ->
        state

      buf ->
        BufferServer.move_to(buf, {line, col})
        state
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec severity_icon(Diagnostics.Diagnostic.severity()) :: String.t()
  defp severity_icon(:error), do: "E"
  defp severity_icon(:warning), do: "W"
  defp severity_icon(:info), do: "I"
  defp severity_icon(:hint), do: "H"
end
