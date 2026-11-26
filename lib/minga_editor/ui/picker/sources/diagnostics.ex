defmodule MingaEditor.UI.Picker.Sources.Diagnostics do
  @moduledoc """
  Picker source for listing buffer diagnostics.

  Invoked via `SPC c x`: shows all diagnostics for the current buffer
  with severity, location, and message. Selecting a diagnostic jumps
  the cursor to that position.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Empty

  alias Minga.Buffer
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer

  @impl true
  @spec title() :: String.t()
  def title, do: "Diagnostics"

  @doc "Opens the diagnostics list for the active buffer, even when it has nothing to report."
  @spec open(MingaEditor.State.t()) :: MingaEditor.State.t()
  def open(state),
    do: MingaEditor.PickerUI.open(state, __MODULE__, %{buffer: state.workspace.buffers.active})

  @doc """
  With nothing to report, says so and whether a language server checks the file, then offers to restart it or install one, and to show what ran.
  """
  @impl true
  @spec empty(Empty.request()) :: Empty.t()
  def empty(%{query: query, total: total} = request) do
    checked? = checked?(request)

    %Empty{
      typing?: total > 0,
      title: empty_title(String.trim(query)),
      why:
        if(checked?,
          do: "Its language server reports nothing.",
          else: "No language server checks this file."
        ),
      rows: [first_step(checked?), Empty.command_row(:lsp_info, "Show what ran")]
    }
  end

  @spec empty_title(String.t()) :: String.t()
  defp empty_title(""), do: "No problems in this file."
  defp empty_title(query), do: "No problem matches #{Empty.quoted(query)}."

  @spec checked?(Empty.request()) :: boolean()
  defp checked?(%{context: %{buffer: buf}}) when is_pid(buf),
    do: SyncServer.clients_for_buffer(buf) != []

  defp checked?(_request), do: false

  @spec first_step(boolean()) :: Item.t()
  defp first_step(true), do: Empty.command_row(:lsp_restart, "Check again")
  defp first_step(false), do: Empty.command_row(:tool_manage, "Install a language server")

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
    |> format_candidates(buf)
  end

  @spec format_candidates([Diagnostic.t()], pid()) :: [Item.t()]
  defp format_candidates(diagnostics, buf) do
    needed =
      for %Diagnostic{encoding: encoding, range: %{start_line: line}} <- diagnostics,
          encoding != :utf8,
          into: MapSet.new(),
          do: line

    lines =
      if MapSet.size(needed) == 0, do: %{}, else: Buffer.lines_at(buf, MapSet.to_list(needed))

    Enum.map(diagnostics, &format_candidate(&1, lines))
  end

  @spec format_candidate(Diagnostic.t(), %{non_neg_integer() => String.t()}) :: Item.t()
  defp format_candidate(diag, lines) do
    {line, byte_col} = Diagnostic.start_position(diag, Map.get(lines, diag.range.start_line, ""))
    icon = severity_icon(diag.severity)
    display_line = line + 1
    display_col = byte_col + 1
    source_tag = if diag.source, do: " (#{diag.source})", else: ""
    label = "#{icon} #{display_line}:#{display_col}  #{diag.message}#{source_tag}"

    %Item{id: {line, byte_col}, label: label}
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:next_step, _step}} = item, state), do: Empty.run_command(item, state)

  def on_select(%Item{id: {line, col}}, state) do
    case state.workspace.buffers.active do
      nil ->
        state

      buf ->
        Buffer.move_to(buf, {line, col})
        state
    end
  end

  @spec severity_icon(Diagnostics.Diagnostic.severity()) :: String.t()
  defp severity_icon(:error), do: "E"
  defp severity_icon(:warning), do: "W"
  defp severity_icon(:info), do: "I"
  defp severity_icon(:hint), do: "H"
end
