defmodule MingaEditor.MouseHoverTooltip do
  @moduledoc """
  Checks the mouse hover position for diagnostics or LSP hover content.

  When the mouse rests over a position for ~500ms (debounced by MouseState),
  this module checks if there's a diagnostic at that position (shows the
  diagnostic message) or triggers an LSP hover request for the symbol.
  """

  alias Minga.Buffer
  alias Minga.Diagnostics
  alias MingaEditor.HoverPopup
  alias MingaEditor.State, as: EditorState
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer

  @type state :: EditorState.t()

  @doc """
  Checks the current hover position for tooltippable content.

  Priority: diagnostics first (immediate feedback), then LSP hover
  (async, will arrive via the lsp_response handler).
  """
  @spec check_hover(state()) :: state()
  def check_hover(%{workspace: %{mouse: %{hover_pos: nil}}} = state), do: state
  def check_hover(%{workspace: %{buffers: %{active: nil}}} = state), do: state

  def check_hover(%{workspace: %{mouse: %{hover_pos: {row, col}}}} = state) do
    # Convert screen position to buffer position
    buf = state.workspace.buffers.active
    vp = state.workspace.viewport

    buf_line = row + vp.top - 1
    # Approximate: col minus gutter width
    gutter_w = Map.get(state, :layout, nil) |> gutter_width()
    buf_col = max(0, col - gutter_w)

    # Check for diagnostics first
    case check_diagnostic(buf, buf_line) do
      nil ->
        # No diagnostic; send LSP hover request (async)
        send_hover_request(state, buf, buf_line, buf_col, row, col)

      message ->
        popup = HoverPopup.new(message, row, col)
        EditorState.set_hover_popup(state, popup)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec check_diagnostic(pid(), non_neg_integer()) :: String.t() | nil
  defp check_diagnostic(buf, line) do
    file_path = Buffer.file_path(buf)

    case file_path do
      nil ->
        nil

      path ->
        uri = SyncServer.path_to_uri(path)
        diags = Diagnostics.on_line(uri, line)

        case diags do
          [] -> nil
          [first | _] -> first.message
        end
    end
  catch
    :exit, _ -> nil
  end

  @spec send_hover_request(
          state(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          integer(),
          integer()
        ) :: state()
  defp send_hover_request(state, buf, buf_line, buf_col, row, col) do
    clients = SyncServer.clients_for_buffer(buf)

    case clients do
      [] ->
        state

      [client | _] ->
        file_path = Buffer.file_path(buf)

        case file_path do
          nil ->
            state

          path ->
            uri = SyncServer.path_to_uri(path)

            params = %{
              "textDocument" => %{"uri" => uri},
              "position" => %{"line" => buf_line, "character" => buf_col}
            }

            ref = Client.request(client, "textDocument/hover", params)

            # Store the mouse screen position for the hover popup anchor
            state =
              put_in(
                state.workspace.lsp_pending,
                Map.put(state.workspace.lsp_pending, ref, {:hover_mouse, row, col})
              )

            state
        end
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  @spec gutter_width(term()) :: non_neg_integer()
  defp gutter_width(nil), do: 4
  defp gutter_width(layout), do: Map.get(layout, :gutter_width, 4)
end
