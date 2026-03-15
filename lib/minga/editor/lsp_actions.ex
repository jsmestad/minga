defmodule Minga.Editor.LspActions do
  @moduledoc """
  One-shot LSP request/response handlers for go-to-definition and hover.

  Follows the same async pattern as completion: sends a request via
  `Client.request/3`, stores the reference in `state.lsp_pending`, and
  processes the response when it arrives in `Editor.handle_info`.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.HoverPopup
  alias Minga.Editor.State, as: EditorState
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer

  @type state :: EditorState.t()

  # ── Request senders ────────────────────────────────────────────────────────

  @doc "Sends a textDocument/definition request for the symbol under the cursor."
  @spec goto_definition(state()) :: state()
  def goto_definition(%{buffers: %{active: nil}} = state) do
    %{state | status_msg: "No active buffer"}
  end

  def goto_definition(%{buffers: %{active: buf}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        %{state | status_msg: "No language server"}

      client ->
        send_lsp_request(state, client, buf, "textDocument/definition", :definition)
    end
  end

  @doc "Sends a textDocument/hover request for the symbol under the cursor."
  @spec hover(state()) :: state()
  def hover(%{buffers: %{active: nil}} = state) do
    %{state | status_msg: "No active buffer"}
  end

  def hover(%{buffers: %{active: buf}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        %{state | status_msg: "No language server"}

      client ->
        send_lsp_request(state, client, buf, "textDocument/hover", :hover)
    end
  end

  # ── Response handlers ──────────────────────────────────────────────────────

  @doc """
  Handles a textDocument/definition response.

  Parses Location or LocationLink results and navigates to the target.
  Sets the `'` mark before jumping so `''` returns to the previous position.
  """
  @spec handle_definition_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_definition_response(state, {:error, error}) do
    Minga.Log.debug(:lsp, "Definition request failed: #{inspect(error)}")
    %{state | status_msg: "Definition request failed"}
  end

  def handle_definition_response(state, {:ok, nil}) do
    %{state | status_msg: "No definition found"}
  end

  def handle_definition_response(state, {:ok, []}) do
    %{state | status_msg: "No definition found"}
  end

  def handle_definition_response(state, {:ok, result}) do
    case parse_location(result) do
      nil ->
        %{state | status_msg: "No definition found"}

      {uri, line, col} ->
        jump_to_location(state, uri, line, col)
    end
  end

  @doc """
  Handles a textDocument/hover response.

  Creates a floating hover popup with markdown-rendered content anchored
  at the cursor position. Falls back to a minibuffer message if the
  content is very short (single line, no markdown).
  """
  @spec handle_hover_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_hover_response(state, {:error, error}) do
    Minga.Log.debug(:lsp, "Hover request failed: #{inspect(error)}")
    %{state | status_msg: "Hover request failed"}
  end

  def handle_hover_response(state, {:ok, nil}) do
    %{state | status_msg: "No hover information"}
  end

  def handle_hover_response(state, {:ok, %{"contents" => contents}}) do
    markdown = extract_hover_markdown(contents)

    case markdown do
      "" ->
        %{state | status_msg: "No hover information"}

      text ->
        {cursor_row, cursor_col} = hover_cursor_screen_position(state)
        popup = HoverPopup.new(text, cursor_row, cursor_col)
        %{state | hover_popup: popup}
    end
  end

  def handle_hover_response(state, {:ok, _}) do
    %{state | status_msg: "No hover information"}
  end

  # ── Location parsing ───────────────────────────────────────────────────────

  @doc """
  Parses an LSP definition response into `{uri, line, col}`.

  Handles single Location, array of Locations, and LocationLink format.
  When multiple locations are returned, picks the first one.
  """
  @spec parse_location(term()) :: {String.t(), non_neg_integer(), non_neg_integer()} | nil
  def parse_location(locations) when is_list(locations) do
    case locations do
      [first | _] -> parse_single_location(first)
      [] -> nil
    end
  end

  def parse_location(location) when is_map(location) do
    parse_single_location(location)
  end

  def parse_location(_), do: nil

  # ── Hover text extraction ──────────────────────────────────────────────────

  @doc """
  Extracts plain text from LSP hover contents.

  Handles MarkupContent (`%{"kind" => ..., "value" => ...}`), plain strings,
  and MarkedString arrays. Strips markdown fences for readability.
  """
  @spec extract_hover_text(term()) :: String.t()
  def extract_hover_text(%{"kind" => _, "value" => value}) when is_binary(value) do
    strip_markdown(value)
  end

  def extract_hover_text(text) when is_binary(text) do
    strip_markdown(text)
  end

  def extract_hover_text(items) when is_list(items) do
    items
    |> Enum.map(&extract_hover_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" | ")
  end

  def extract_hover_text(%{"language" => _, "value" => value}) when is_binary(value) do
    String.trim(value)
  end

  def extract_hover_text(_), do: ""

  # ── Private ────────────────────────────────────────────────────────────────

  @spec lsp_client_for(state(), pid()) :: pid() | nil
  defp lsp_client_for(_state, buffer_pid) do
    case SyncServer.clients_for_buffer(buffer_pid) do
      [client | _] -> client
      [] -> nil
    end
  end

  @spec send_lsp_request(state(), pid(), pid(), String.t(), atom()) :: state()
  defp send_lsp_request(state, client, buffer_pid, method, kind) do
    file_path = BufferServer.file_path(buffer_pid)

    case file_path do
      nil ->
        %{state | status_msg: "Buffer has no file path"}

      path ->
        uri = SyncServer.path_to_uri(path)
        {line, col} = BufferServer.cursor(buffer_pid)

        params = %{
          "textDocument" => %{"uri" => uri},
          "position" => %{"line" => line, "character" => col}
        }

        ref = Client.request(client, method, params)
        put_in(state.lsp_pending, Map.put(state.lsp_pending, ref, kind))
    end
  end

  @spec parse_single_location(map()) ::
          {String.t(), non_neg_integer(), non_neg_integer()} | nil
  defp parse_single_location(%{"uri" => uri, "range" => range}) do
    {line, col} = extract_position(range)
    {uri, line, col}
  end

  # LocationLink format
  defp parse_single_location(%{"targetUri" => uri, "targetRange" => range}) do
    {line, col} = extract_position(range)
    {uri, line, col}
  end

  defp parse_single_location(_), do: nil

  @spec extract_position(map()) :: {non_neg_integer(), non_neg_integer()}
  defp extract_position(%{"start" => %{"line" => line, "character" => col}}) do
    {line, col}
  end

  defp extract_position(_), do: {0, 0}

  @spec jump_to_location(state(), String.t(), non_neg_integer(), non_neg_integer()) :: state()
  defp jump_to_location(state, uri, line, col) do
    target_path = SyncServer.uri_to_path(uri)
    current_path = BufferServer.file_path(state.buffers.active)

    # Set jump mark before navigating
    state = set_jump_mark(state)

    if target_path == current_path do
      # Same file: just move the cursor
      BufferServer.move_to(state.buffers.active, {line, col})
      state
    else
      # Different file: open it, then move cursor
      state = open_or_switch_to_file(state, target_path)
      BufferServer.move_to(state.buffers.active, {line, col})
      state
    end
  end

  @spec open_or_switch_to_file(state(), String.t()) :: state()
  defp open_or_switch_to_file(state, file_path) do
    # Check if already open
    idx =
      Enum.find_index(state.buffers.list, fn buf ->
        Process.alive?(buf) and BufferServer.file_path(buf) == file_path
      end)

    case idx do
      nil ->
        case Commands.start_buffer(file_path) do
          {:ok, pid} -> Commands.add_buffer(state, pid)
          {:error, _reason} -> %{state | status_msg: "Could not open #{file_path}"}
        end

      i ->
        EditorState.switch_buffer(state, i)
    end
  end

  @spec set_jump_mark(state()) :: state()
  defp set_jump_mark(%{buffers: %{active: buf}} = state) when is_pid(buf) do
    pos = BufferServer.cursor(buf)
    %{state | vim: %{state.vim | last_jump_pos: pos}}
  end

  defp set_jump_mark(state), do: state

  @doc """
  Extracts raw markdown text from LSP hover contents.

  Preserves markdown formatting for floating window rendering.
  Handles MarkupContent, plain strings, and MarkedString arrays.
  """
  @spec extract_hover_markdown(term()) :: String.t()
  def extract_hover_markdown(%{"kind" => "markdown", "value" => value}) when is_binary(value) do
    String.trim(value)
  end

  def extract_hover_markdown(%{"kind" => "plaintext", "value" => value}) when is_binary(value) do
    String.trim(value)
  end

  def extract_hover_markdown(%{"kind" => _, "value" => value}) when is_binary(value) do
    String.trim(value)
  end

  def extract_hover_markdown(text) when is_binary(text) do
    String.trim(text)
  end

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

  # Computes the cursor's screen position for anchoring the hover popup.
  # Uses the last rendered cursor position from the compose stage.
  @spec hover_cursor_screen_position(state()) :: {non_neg_integer(), non_neg_integer()}
  defp hover_cursor_screen_position(state) do
    # Use the viewport cursor position from the active window
    buf = state.buffers.active

    if buf do
      {line, col} = BufferServer.cursor(buf)
      # Approximate screen position: line offset from viewport top + gutter
      vp = state.viewport
      screen_row = line - vp.top + 1
      screen_col = col + 4
      {clamp(screen_row, 1, vp.rows - 2), clamp(screen_col, 0, vp.cols - 1)}
    else
      {div(state.viewport.rows, 2), div(state.viewport.cols, 2)}
    end
  end

  @spec clamp(integer(), integer(), integer()) :: integer()
  defp clamp(val, lo, hi), do: max(lo, min(val, hi))

  @spec strip_markdown(String.t()) :: String.t()
  defp strip_markdown(text) do
    text
    # Remove code fences
    |> String.replace(~r/```\w*\n?/, "")
    # Collapse multiple newlines into single space for minibuffer display
    |> String.replace(~r/\n+/, " ")
    |> String.trim()
  end
end
