defmodule MingaEditor.UI.Picker.WorkspaceSymbolSource do
  @moduledoc """
  Picker source for workspace-wide symbol search.

  The language server filters workspace symbols. Each picker query is sent as a `workspace/symbol` request to the first language server attached to the active buffer, and the picker shows the server's rows in the server's order. The picker does not filter them again locally, so a row that the server matched (for example through its container name) stays visible.

  An empty query sends no request, because servers answer it with every symbol in the workspace. Requests run in the picker fetch worker, never in the Editor process. `MingaEditor.PickerUI` starts a new fetch for every query edit; the effect scheduler stops the superseded worker, and `Minga.LSP.Client` sends `$/cancelRequest` when the requesting worker exits. Each fetch is tagged with its query (`fetch_identity/1`), so a late result for an older query is discarded.

  Opened via `SPC s w` or the `:workspace_symbols` command.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias MingaEditor.State, as: EditorState
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @request_timeout 5_000

  @impl true
  @spec title() :: String.t()
  def title, do: "Workspace Symbols"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{buffers: %{active: buf}} = context) when is_pid(buf) do
    case fetch_identity(context) do
      "" -> []
      query -> request_symbols(buf, query)
    end
  end

  def candidates(_state), do: []

  @doc "Returns the query a fetch asks the server for; it tags the fetch so results for older queries are stale."
  @spec fetch_identity(Context.t()) :: String.t()
  def fetch_identity(%Context{picker_ui: %{source: __MODULE__, picker: %Picker{query: query}}}),
    do: query

  # A picker that is opening has no query yet; any other open picker's query belongs to that picker.
  def fetch_identity(%Context{}), do: ""

  @spec request_symbols(pid(), String.t()) :: [Item.t()]
  defp request_symbols(buf, query) do
    case lsp_client_for(buf) do
      nil ->
        []

      client ->
        # minga:allow-blocking — candidates/1 runs in the picker fetch worker (async?/0 is true)
        case Client.request_sync(
               client,
               "workspace/symbol",
               %{"query" => query},
               @request_timeout
             ) do
          {:ok, symbols} when is_list(symbols) -> Enum.map(symbols, &format_symbol/1)
          _ -> []
        end
    end
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {path, line, col}}, state) do
    state = MingaEditor.Editing.record_jump_here(state)
    state = open_or_switch_to_file(state, path)

    case state.workspace.buffers.active do
      nil -> state
      buf -> Buffer.move_to(buf, {line, col})
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
      description: description
    }
  end

  @spec lsp_client_for(pid()) :: pid() | nil
  defp lsp_client_for(buffer_pid) do
    case SyncServer.clients_for_buffer(buffer_pid) do
      [client | _] -> client
      [] -> nil
    end
  end

  @spec open_or_switch_to_file(EditorState.t(), String.t()) :: EditorState.t()
  defp open_or_switch_to_file(state, file_path) do
    case MingaEditor.Handlers.BufferRegistry.open_or_activate_path(state, file_path) do
      {:ok, new_state, _pid, _status} ->
        new_state

      {:error, _} ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "Could not open #{file_path}"
        )
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
