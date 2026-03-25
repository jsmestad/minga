defmodule Minga.Picker.WorkspaceSymbolSource do
  @moduledoc """
  Picker source for workspace-wide symbol search.

  Sends a `workspace/symbol` request with a query string and displays
  the results in the picker. The initial query is empty (""), which most
  LSP servers interpret as "return common/recent symbols." The picker's
  built-in fuzzy filtering narrows results client-side.

  Opened via `SPC s w` or the `:workspace_symbols` command.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.State, as: EditorState
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer
  alias Minga.Picker.Item
  alias Minga.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Workspace Symbols"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(%EditorState{workspace: %{buffers: %{active: buf}}} = _state) when is_pid(buf) do
    # Send a synchronous workspace/symbol request with empty query.
    # Most servers return commonly-used symbols for "".
    case lsp_client_for(buf) do
      nil ->
        []

      client ->
        case Client.request_sync(client, "workspace/symbol", %{"query" => ""}, 5_000) do
          {:ok, symbols} when is_list(symbols) ->
            Enum.map(symbols, &format_symbol/1)

          _ ->
            []
        end
    end
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {path, line, col}}, state) do
    state = set_jump_mark(state)
    state = open_or_switch_to_file(state, path)

    case state.workspace.buffers.active do
      nil -> state
      buf -> BufferServer.move_to(buf, {line, col})
    end

    state
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state) do
    Source.restore_or_keep(state)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec format_symbol(map()) :: Item.t()
  defp format_symbol(sym) do
    location = sym["location"]
    uri = location["uri"]
    range = location["range"]
    start = range["start"]
    line = start["line"]
    col = start["character"]
    path = SyncServer.uri_to_path(uri)

    name = sym["name"]
    kind = symbol_kind_icon(sym["kind"])
    container = Map.get(sym, "containerName", "")

    label = "#{kind} #{name}"
    display_path = shorten_path(path)
    line_num = line + 1

    description =
      if container != "" do
        "#{container}  #{display_path}:#{line_num}"
      else
        "#{display_path}:#{line_num}"
      end

    %Item{
      id: {path, line, col},
      label: label,
      description: description,
      two_line: true
    }
  end

  @spec lsp_client_for(pid()) :: pid() | nil
  defp lsp_client_for(buffer_pid) do
    case SyncServer.clients_for_buffer(buffer_pid) do
      [client | _] -> client
      [] -> nil
    end
  end

  @spec set_jump_mark(EditorState.t()) :: EditorState.t()
  defp set_jump_mark(%EditorState{workspace: %{buffers: %{active: buf}}} = state) when is_pid(buf) do
    pos = BufferServer.cursor(buf)
    %{state | workspace: %{state.workspace | vim: %{state.workspace.vim | last_jump_pos: pos}}}
  end

  defp set_jump_mark(state), do: state

  @spec open_or_switch_to_file(EditorState.t(), String.t()) :: EditorState.t()
  defp open_or_switch_to_file(state, file_path) do
    idx =
      Enum.find_index(state.workspace.buffers.list, fn buf ->
        try do
          BufferServer.file_path(buf) == file_path
        catch
          :exit, _ -> false
        end
      end)

    case idx do
      nil ->
        case Commands.start_buffer(file_path) do
          {:ok, pid} -> Commands.add_buffer(state, pid)
          {:error, _} -> %{state | status_msg: "Could not open #{file_path}"}
        end

      i ->
        EditorState.switch_buffer(state, i)
    end
  end

  @spec shorten_path(String.t()) :: String.t()
  defp shorten_path(path) do
    case Minga.Project.root() do
      nil -> path
      root -> Path.relative_to(path, root)
    end
  end

  @spec symbol_kind_icon(non_neg_integer() | nil) :: String.t()
  defp symbol_kind_icon(2), do: "󰆧"
  defp symbol_kind_icon(5), do: ""
  defp symbol_kind_icon(6), do: "󰊕"
  defp symbol_kind_icon(8), do: ""
  defp symbol_kind_icon(9), do: ""
  defp symbol_kind_icon(10), do: ""
  defp symbol_kind_icon(11), do: ""
  defp symbol_kind_icon(12), do: "󰊕"
  defp symbol_kind_icon(13), do: ""
  defp symbol_kind_icon(14), do: ""
  defp symbol_kind_icon(23), do: ""
  defp symbol_kind_icon(_), do: "󰊕"
end
