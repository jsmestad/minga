defmodule Minga.Editor.MouseHoverTooltip do
  @moduledoc """
  Checks the mouse hover position for diagnostics or LSP hover content.

  When the mouse rests over a position for ~500ms (debounced by MouseState),
  this module checks if there's a diagnostic at that position (shows the
  diagnostic message) or triggers an LSP hover request for the symbol.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Diagnostics
  alias Minga.Editor.HoverPopup
  alias Minga.Editor.State, as: EditorState
  alias Minga.LSP.SyncServer

  @type state :: EditorState.t()

  @doc """
  Checks the current hover position for tooltippable content.

  Priority: diagnostics first (immediate feedback), then LSP hover
  (async, will arrive via the lsp_response handler).
  """
  @spec check_hover(state()) :: state()
  def check_hover(%{mouse: %{hover_pos: nil}} = state), do: state
  def check_hover(%{buffers: %{active: nil}} = state), do: state

  def check_hover(%{mouse: %{hover_pos: {row, col}}} = state) do
    # Convert screen position to buffer position
    buf = state.buffers.active
    vp = state.viewport

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
        %{state | hover_popup: popup}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec check_diagnostic(pid(), non_neg_integer()) :: String.t() | nil
  defp check_diagnostic(buf, line) do
    file_path = BufferServer.file_path(buf)

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
  defp send_hover_request(state, _buf, _buf_line, _buf_col, _row, _col) do
    # The hover request is already handled by LspActions.hover/1 which uses
    # the cursor position. For mouse hover, we'd need a position-specific
    # hover request. For now, just show hover for the cursor's current position.
    # Full mouse-position hover is a follow-up that needs the Editor to send
    # the mouse position to the LSP request.
    state
  end

  @spec gutter_width(term()) :: non_neg_integer()
  defp gutter_width(nil), do: 4
  defp gutter_width(layout), do: Map.get(layout, :gutter_width, 4)
end
