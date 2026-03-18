defmodule Minga.Editor.Commands.Diagnostics do
  @moduledoc """
  Commands for navigating diagnostics.

  `]d` jumps to the next diagnostic, `[d` to the previous.
  Both wrap around at buffer boundaries.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Diagnostics
  alias Minga.Diagnostics.PickerSource, as: DiagPickerSource
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.LSP.Client
  alias Minga.LSP.Supervisor, as: LSPSupervisor
  alias Minga.LSP.SyncServer

  @command_specs [
    {:next_diagnostic, "Jump to next diagnostic", true},
    {:prev_diagnostic, "Jump to previous diagnostic", true},
    {:diagnostic_list, "Show diagnostic list picker", true}
  ]

  @doc "Executes a diagnostic or LSP command."
  @spec execute(
          EditorState.t(),
          :next_diagnostic | :prev_diagnostic | :diagnostic_list | :lsp_info
        ) :: EditorState.t()
  def execute(%{buffers: %{active: nil}} = state, _cmd), do: state

  def execute(state, :diagnostic_list) do
    PickerUI.open(state, DiagPickerSource)
  end

  def execute(%{buffers: %{active: buf}} = state, :next_diagnostic) do
    navigate(state, buf, &Diagnostics.next/2)
  end

  def execute(%{buffers: %{active: buf}} = state, :prev_diagnostic) do
    navigate(state, buf, &Diagnostics.prev/2)
  end

  def execute(state, :lsp_info) do
    clients = LSPSupervisor.all_clients()

    case clients do
      [] ->
        %{state | status_msg: "No language servers running"}

      _ ->
        info =
          Enum.map_join(clients, " | ", fn pid ->
            try do
              name = Client.server_name(pid)
              status = Client.status(pid)
              encoding = Client.encoding(pid)
              "#{name}: #{status} (#{encoding})"
            catch
              :exit, _ -> "unknown: dead"
            end
          end)

        %{state | status_msg: "LSP: #{info}"}
    end
  end

  @spec navigate(EditorState.t(), pid(), (String.t(), non_neg_integer() -> term())) ::
          EditorState.t()
  defp navigate(state, buf, find_fn) do
    file_path = BufferServer.file_path(buf)

    case file_path do
      nil ->
        %{state | status_msg: "No file — no diagnostics"}

      path ->
        uri = SyncServer.path_to_uri(path)
        {cursor_line, _col} = BufferServer.cursor(buf)

        case find_fn.(uri, cursor_line) do
          nil ->
            %{state | status_msg: "No diagnostics"}

          diag ->
            BufferServer.move_to(buf, {diag.range.start_line, diag.range.start_col})
            %{state | status_msg: diag.message}
        end
    end
  end

  @impl Minga.Command.Provider
  def __commands__ do
    Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
      %Minga.Command{
        name: name,
        description: desc,
        requires_buffer: requires_buffer,
        execute: fn state -> execute(state, name) end
      }
    end)
  end
end
