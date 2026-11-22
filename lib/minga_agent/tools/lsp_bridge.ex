defmodule MingaAgent.Tools.LspBridge do
  @moduledoc """
  Shared LSP lookup infrastructure for agent tools.

  Agent tools receive a path with every symlink resolved, but a language server knows an open buffer by the name the user opened it with, which can be a symlink. `document_for_path/1` bridges the two: it finds the buffer visiting the file, then returns the client, the buffer's own document URI, and the buffer that holds the content the server has. Requests about the document use that URI, and positions are computed from that buffer.

  ```
  real path → Buffer.pid_for_file → buffer → SyncServer.buffer_uri → document URI
                                           → SyncServer.clients_for_buffer → client
  ```

  The agent always sees real paths. Paths decoded from result URIs are resolved through every symlink, so a location the server reports under a link path names the same file the agent passes back.
  """

  alias Minga.Buffer
  alias Minga.LSP.Client
  alias Minga.LSP.Location
  alias Minga.LSP.PositionEncoding
  alias Minga.LSP.SyncServer
  alias Minga.LSP.Supervisor, as: LSPSupervisor
  alias Minga.Project.Root

  @typedoc """
  An open document as a language server knows it.

  `uri` is the URI the server opened the document under, and `buffer` holds the content the server has.
  """
  @type document :: %{client: pid(), uri: String.t(), buffer: pid()}

  @typedoc "Result of the document lookup."
  @type document_result :: {:ok, document()} | {:error, String.t()}

  @typedoc "Result of a client lookup."
  @type client_result :: {:ok, pid()} | {:error, String.t()}

  @typedoc "A parsed LSP location: `{file_path, line, col}`."
  @type location :: {String.t(), non_neg_integer(), non_neg_integer()}

  # ── Document lookup ────────────────────────────────────────────────────────

  @doc """
  Finds the open document for a file path and the LSP client attached to it.

  The buffer is found by the file it visits, so a buffer opened through a symlink is found by the real path and the reverse. Returns `{:error, reason}` with a human-readable explanation the agent can use to understand why LSP is unavailable.
  """
  @spec document_for_path(String.t()) :: document_result()
  def document_for_path(path) when is_binary(path) do
    with {:ok, buffer} <- open_buffer(path),
         {:ok, uri} <- buffer_uri(buffer, path) do
      attached_document(buffer, uri, path)
    end
  rescue
    _ -> lookup_failed(path)
  catch
    :exit, _ -> lookup_failed(path)
  end

  @spec open_buffer(String.t()) :: {:ok, pid()} | {:error, String.t()}
  defp open_buffer(path) do
    case Buffer.pid_for_file(Path.expand(path)) do
      {:ok, buffer} -> {:ok, buffer}
      :not_found -> {:error, no_buffer(path)}
    end
  end

  @spec buffer_uri(pid(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp buffer_uri(buffer, path) do
    case SyncServer.buffer_uri(buffer) do
      nil -> {:error, no_buffer(path)}
      uri -> {:ok, uri}
    end
  end

  @spec attached_document(pid(), String.t(), String.t()) :: document_result()
  defp attached_document(buffer, uri, path) do
    case SyncServer.clients_for_buffer(buffer) do
      [client | _] ->
        {:ok, %{client: client, uri: uri, buffer: buffer}}

      [] ->
        {:error,
         "No language server attached to #{Path.basename(path)}. " <>
           "The file is open but no LSP server is configured for this filetype."}
    end
  end

  @spec no_buffer(String.t()) :: String.t()
  defp no_buffer(path) do
    "No buffer open for #{Path.basename(path)}. " <>
      "The file must be open in the editor for LSP features to work."
  end

  @spec lookup_failed(String.t()) :: {:error, String.t()}
  defp lookup_failed(path) do
    {:error, "Could not look up LSP client for #{Path.basename(path)}."}
  end

  @doc """
  Returns any available LSP client, preferring the one attached to the given path.

  Falls back to any running client from `LSP.Supervisor.all_clients/0`.
  Useful for workspace-scoped requests like `workspace/symbol` that don't
  need a specific file's client.
  """
  @spec any_client(String.t() | nil) :: client_result()
  def any_client(path \\ nil) do
    if path do
      case document_for_path(path) do
        {:ok, %{client: client}} -> {:ok, client}
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

  Use the document URI from `document_for_path/1` for an open document. This URI names the path itself, which a server knows only when the document is not open.
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
  Builds `textDocument/position` params for an open document.

  The params name the document by its own URI. The position is converted to `encoding`, the document client's negotiated encoding, using the line from the document's buffer, which is the content the server has.
  """
  @spec position_params(
          document(),
          non_neg_integer(),
          non_neg_integer(),
          PositionEncoding.encoding()
        ) :: map()
  def position_params(document, line, col, encoding) do
    line_text = document_line(document, line)

    %{
      "textDocument" => %{"uri" => document.uri},
      "position" => PositionEncoding.to_lsp({line, col}, line_text, encoding)
    }
  end

  @spec document_line(document(), non_neg_integer()) :: String.t()
  defp document_line(%{buffer: buffer}, line) do
    buffer |> Buffer.lines(line, 1) |> List.first() || ""
  catch
    :exit, _ -> ""
  end

  # ── Response parsing helpers ───────────────────────────────────────────────

  @doc """
  Parses an LSP Location or LocationLink response into `{path, line, col}`.

  Handles single Location, array of Locations, and LocationLink format.
  Returns the first location when multiple are present.
  """
  @spec parse_location(term()) :: location() | nil
  def parse_location(response) do
    case Location.first(response) do
      nil -> nil
      {uri, line, col} -> {result_path(uri), line, col}
    end
  end

  @doc """
  Parses all locations from an LSP response into a list of `{path, line, col, context}` tuples.
  """
  @spec parse_all_locations(term()) :: [
          {String.t(), non_neg_integer(), non_neg_integer(), String.t()}
        ]
  def parse_all_locations(locations) when is_list(locations) do
    for location <- locations, decoded = Location.decode(location) do
      {uri, line, col} = decoded
      path = result_path(uri)
      context = read_line_content(path, line)
      {path, line, col, context}
    end
  end

  def parse_all_locations(_), do: []

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
      {line, col} = Location.range_start(range)
      name = sym["name"]
      kind = symbol_kind_name(sym["kind"])
      indent = String.duplicate("  ", depth)
      label = "#{indent}#{kind}  #{name}"

      path =
        case sym do
          %{"location" => %{"uri" => uri}} -> result_path(uri)
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
    {line, col} = Location.range_start(range)
    path = result_path(uri)
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

  # The agent sees real paths: a server reports an open document under the
  # name the buffer was opened with, which can be a symlink. A path that does
  # not resolve, such as a deleted file, is kept as the server named it.
  @spec result_path(String.t()) :: String.t()
  defp result_path(uri) do
    path = uri_to_path(uri)

    case Root.canonical_path(path) do
      {:ok, real_path} -> real_path
      {:error, _reason} -> path
    end
  end

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
