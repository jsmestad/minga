defmodule MingaEditor.UI.Picker.Sources.Diagnostics do
  @moduledoc """
  Picker source for listing buffer diagnostics.

  Invoked via `SPC c d` — shows all diagnostics for the current buffer
  with severity, location, and message. Selecting a diagnostic jumps
  the cursor to that position.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Context

  alias Minga.Buffer
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer

  @impl true
  @spec title() :: String.t()
  def title, do: "Diagnostics"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{buffers: %{active: buf}}) when is_pid(buf) do
    buf
    |> Buffer.file_path()
    |> candidates_for_path(buf)
  end

  def candidates(_state), do: []

  @spec candidates_for_path(String.t() | nil, pid()) :: [Item.t()]
  defp candidates_for_path(nil, _buf), do: []

  defp candidates_for_path(path, buf) do
    path
    |> SyncServer.path_to_uri()
    |> Diagnostics.for_uri()
    |> Enum.map(&format_candidate(&1, buf))
  end

  @spec format_candidate(Diagnostic.t(), pid()) :: Item.t()
  defp format_candidate(diag, buf) do
    {line, byte_col} = start_position(diag, buf)
    icon = severity_icon(diag.severity)
    display_line = line + 1
    display_col = byte_col + 1
    source_tag = if diag.source, do: " (#{diag.source})", else: ""
    label = "#{icon} #{display_line}:#{display_col}  #{diag.message}#{source_tag}"

    %Item{id: {line, byte_col}, label: label}
  end

  @spec start_position(Diagnostic.t(), pid()) :: Diagnostic.position()
  defp start_position(%Diagnostic{} = diag, buf) do
    diag
    |> start_line_text(buf)
    |> then(&Diagnostic.start_position(diag, &1))
  end

  @spec start_line_text(Diagnostic.t(), pid()) :: String.t()
  defp start_line_text(%Diagnostic{} = diag, buf) do
    case Buffer.lines(buf, diag.range.start_line, 1) do
      [text] -> text
      _ -> ""
    end
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {line, col}}, state) do
    case state.workspace.buffers.active do
      nil ->
        state

      buf ->
        Buffer.move_to(buf, {line, col})
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
