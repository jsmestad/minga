defmodule MingaAgent.Tools.LspBridge do
  @moduledoc """
  Shared LSP lookup infrastructure for agent tools.

  Encapsulates the file-path-to-LSP-client lookup chain that all agent
  LSP tools need. Also provides response parsing helpers extracted from
  `Minga.Editor.LspActions` so agent tools and the editor share the same
  logic without the agent needing access to `EditorState`.

  The lookup chain:
  ```
  file_path → Path.expand → Buffer.pid_for_path → SyncServer.clients_for_buffer → client_pid
  file_path → SyncServer.path_to_uri → Diagnostics.for_uri (direct ETS read)
  ```
  """

  alias Minga.Buffer
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer
  alias Minga.LSP.Supervisor, as: LSPSupervisor

  @typedoc "Result of the client lookup chain."
  @type client_result :: {:ok, pid()} | {:error, String.t()}

  @typedoc "A parsed LSP location: `{file_path, line, col}`."
  @type location :: {String.t(), non_neg_integer(), non_neg_integer()}

  # ── Client lookup ──────────────────────────────────────────────────────────

  @doc """
  Resolves a file path to an LSP client pid.

  Walks the lookup chain: expand path → find buffer pid → find attached
  LSP clients. Returns `{:ok, client_pid}` or `{:error, reason}` with a
  human-readable explanation the agent can use to understand why LSP is
  unavailable.
  """
  @spec client_for_path(String.t()) :: client_result()
  def client_for_path(path) when is_binary(path) do
    abs_path = Path.expand(path)

    case Buffer.Server.pid_for_path(abs_path) do
      {:ok, buf_pid} ->
        case SyncServer.clients_for_buffer(buf_pid) do
          [client | _] ->
            {:ok, client}

          [] ->
            {:error,
             "No language server attached to #{Path.basename(path)}. " <>
               "The file is open but no LSP server is configured for this filetype."}
        end

      :not_found ->
        {:error,
         "No buffer open for #{Path.basename(path)}. " <>
           "The file must be open in the editor for LSP features to work."}
    end
  rescue
    _ ->
      {:error, "Could not look up LSP client for #{Path.basename(path)}."}
  end

  @doc """
  Returns any available LSP client, preferring one for the given path.

  Falls back to any running client from `LSP.Supervisor.all_clients/0`.
  Useful for workspace-scoped requests like `workspace/symbol` that don't
  need a specific file's client.
  """
  @spec any_client(String.t() | nil) :: client_result()
  def any_client(path \\ nil) do
    if path do
      case client_for_path(path) do
        {:ok, _} = ok -> ok
        {:error, _} -> first_available_client()
      end
    else
      first_available_client()
    end
  end

  @spec first_available_client() :: client_result()
  defp first_available_client do
    case LSPSupervisor.all_clients() do
      [client | _] -> {:ok, client}
      [] -> {:error, "No language servers are running."}
    end
  rescue
    _ -> {:error, "LSP supervisor is not running."}
  end

  @doc """
  Converts a file path to an LSP URI.
  """
  @spec path_to_uri(String.t()) :: String.t()
  def path_to_uri(path), do: SyncServer.path_to_uri(path)

  @doc """
  Converts an LSP URI to a file path.
  """
  @spec uri_to_path(String.t()) :: String.t()
  def uri_to_path(uri), do: SyncServer.uri_to_path(uri)

  @doc """
  Sends a synchronous LSP request and returns the result.

  Wraps `Client.request_sync/4` with a configurable timeout.
  """
  @spec request_sync(pid(), String.t(), map(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def request_sync(client, method, params, timeout \\ 30_000) do
    Client.request_sync(client, method, params, timeout)
  end

  # ── Position params builder ────────────────────────────────────────────────

  @doc """
  Builds standard LSP textDocument/position params from a file path, line, and column.
  """
  @spec position_params(String.t(), non_neg_integer(), non_neg_integer()) :: map()
  def position_params(path, line, col) do
    %{
      "textDocument" => %{"uri" => path_to_uri(path)},
      "position" => %{"line" => line, "character" => col}
    }
  end

  # ── Response parsing helpers ───────────────────────────────────────────────

  @doc """
  Parses an LSP Location or LocationLink response into `{path, line, col}`.

  Handles single Location, array of Locations, and LocationLink format.
  Returns the first location when multiple are present.
  """
  @spec parse_location(term()) :: location() | nil
  def parse_location(locations) when is_list(locations) do
    case locations do
      [first | _] -> parse_single_location(first)
      [] -> nil
    end
  end

  def parse_location(location) when is_map(location), do: parse_single_location(location)
  def parse_location(_), do: nil

  @doc """
  Parses all locations from an LSP response into a list of `{path, line, col, context}` tuples.
  """
  @spec parse_all_locations(term()) :: [
          {String.t(), non_neg_integer(), non_neg_integer(), String.t()}
        ]
  def parse_all_locations(locations) when is_list(locations) do
    locations
    |> Enum.map(&parse_single_location/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {path, line, col} ->
      context = read_line_content(path, line)
      {path, line, col, context}
    end)
  end

  def parse_all_locations(_), do: []

  @doc """
  Parses a single LSP Location or LocationLink into `{path, line, col}`.
  """
  @spec parse_single_location(map()) :: location() | nil
  def parse_single_location(%{"uri" => uri, "range" => range}) do
    {line, col} = extract_position(range)
    {uri_to_path(uri), line, col}
  end

  def parse_single_location(%{"targetUri" => uri, "targetRange" => range}) do
    {line, col} = extract_position(range)
    {uri_to_path(uri), line, col}
  end

  def parse_single_location(_), do: nil

  @doc """
  Extracts markdown text from LSP hover contents.

  Handles MarkupContent, plain strings, MarkedString, and arrays thereof.
  """
  @spec extract_hover_markdown(term()) :: String.t()
  def extract_hover_markdown(%{"kind" => _, "value" => value}) when is_binary(value) do
    String.trim(value)
  end

  def extract_hover_markdown(text) when is_binary(text), do: String.trim(text)

  def extract_hover_markdown(items) when is_list(items) do
    items
    |> Enum.map(&extract_hover_markdown/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  def extract_hover_markdown(%{"language" => lang, "value" => value}) when is_binary(value) do
    "```#{lang}\n#{String.trim(value)}\n```"
  end

  def extract_hover_markdown(_), do: ""

  @doc """
  Flattens hierarchical document symbols into a flat list with indentation.

  Returns `[{path_or_empty, line, col, label}]` tuples. The label includes
  indentation to show hierarchy and the symbol kind name.
  """
  @spec flatten_document_symbols([map()], non_neg_integer()) ::
          [{String.t(), non_neg_integer(), non_neg_integer(), String.t()}]
  def flatten_document_symbols(symbols, depth \\ 0) do
    Enum.flat_map(symbols, fn sym ->
      range = sym["range"] || get_in(sym, ["location", "range"])
      {line, col} = extract_position(range)
      name = sym["name"]
      kind = symbol_kind_name(sym["kind"])
      indent = String.duplicate("  ", depth)
      label = "#{indent}#{kind}  #{name}"

      path =
        case sym do
          %{"location" => %{"uri" => uri}} -> uri_to_path(uri)
          _ -> ""
        end

      entry = {path, line, col, label}
      children = Map.get(sym, "children", [])
      [entry | flatten_document_symbols(children, depth + 1)]
    end)
  end

  @doc """
  Converts a workspace symbol to a `{path, line, col, label}` tuple.
  """
  @spec workspace_symbol_to_location(map()) ::
          {String.t(), non_neg_integer(), non_neg_integer(), String.t()}
  def workspace_symbol_to_location(sym) do
    location = sym["location"]
    uri = location["uri"]
    range = location["range"]
    {line, col} = extract_position(range)
    path = uri_to_path(uri)
    kind = symbol_kind_name(sym["kind"])
    container = Map.get(sym, "containerName", "")
    name = sym["name"]
    label = if container != "", do: "#{kind} #{container}.#{name}", else: "#{kind} #{name}"
    {path, line, col, label}
  end

  @doc """
  Maps an LSP SymbolKind integer to a human-readable name.
  """
  @spec symbol_kind_name(non_neg_integer() | nil) :: String.t()
  def symbol_kind_name(1), do: "File"
  def symbol_kind_name(2), do: "Module"
  def symbol_kind_name(3), do: "Namespace"
  def symbol_kind_name(4), do: "Package"
  def symbol_kind_name(5), do: "Class"
  def symbol_kind_name(6), do: "Method"
  def symbol_kind_name(7), do: "Property"
  def symbol_kind_name(8), do: "Field"
  def symbol_kind_name(9), do: "Constructor"
  def symbol_kind_name(10), do: "Enum"
  def symbol_kind_name(11), do: "Interface"
  def symbol_kind_name(12), do: "Function"
  def symbol_kind_name(13), do: "Variable"
  def symbol_kind_name(14), do: "Constant"
  def symbol_kind_name(15), do: "String"
  def symbol_kind_name(16), do: "Number"
  def symbol_kind_name(17), do: "Boolean"
  def symbol_kind_name(18), do: "Array"
  def symbol_kind_name(19), do: "Object"
  def symbol_kind_name(20), do: "Key"
  def symbol_kind_name(21), do: "Null"
  def symbol_kind_name(22), do: "EnumMember"
  def symbol_kind_name(23), do: "Struct"
  def symbol_kind_name(24), do: "Event"
  def symbol_kind_name(25), do: "Operator"
  def symbol_kind_name(26), do: "TypeParameter"
  def symbol_kind_name(_), do: "Symbol"

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec extract_position(map() | nil) :: {non_neg_integer(), non_neg_integer()}
  defp extract_position(%{"start" => %{"line" => line, "character" => col}}), do: {line, col}
  defp extract_position(_), do: {0, 0}

  @spec read_line_content(String.t(), non_neg_integer()) :: String.t()
  defp read_line_content(path, line) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.at(line, "")
        |> String.trim()

      {:error, _} ->
        ""
    end
  end
end
