defmodule MingaEditor.MouseHoverTooltip do
  @moduledoc """
  Checks the mouse hover position for diagnostics or LSP hover content.

  When the mouse rests over a position for ~500ms (debounced by MouseState),
  this module checks if there's a diagnostic at that position (shows the
  diagnostic message) or triggers an LSP hover request for the symbol.
  """

  alias Minga.Buffer
  alias Minga.Diagnostics
  alias MingaEditor.Mouse.HitTest
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
    case HitTest.resolve_buffer(state, row, col) do
      {:buffer, target} ->
        case check_diagnostic(target.buffer, target.line) do
          nil ->
            send_hover_request(state, target.buffer, target.line, target.col, row, col)

          message ->
            popup =
              MingaEditor.HoverPopup.Builder.new(message, row, col, theme: state.appearance.theme)

            MingaEditor.Shell.Traditional.HoverPopupWorkflow.show(state, popup)
        end

      _ ->
        state
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
    with [client | _] <- SyncServer.clients_for_buffer(buf),
         path when is_binary(path) <- Buffer.file_path(buf) do
      uri = SyncServer.path_to_uri(path)

      params = %{
        "textDocument" => %{"uri" => uri},
        "position" => %{"line" => buf_line, "character" => buf_col}
      }

      ref = Client.request(client, "textDocument/hover", params)

      put_lsp_pending(
        state,
        ref,
        {:hover_mouse, row, col, buf, buf_line, buf_col, Buffer.version(buf)}
      )
    else
      _ -> state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  @spec put_lsp_pending(state(), reference(), atom() | tuple()) :: state()
  defp put_lsp_pending(state, ref, kind) do
    %{state | workspace: MingaEditor.Session.State.put_lsp_pending(state.workspace, ref, kind)}
  end
end
