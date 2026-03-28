defmodule Minga.Editor.LspActions do
  @moduledoc """
  LSP request/response handlers for navigation, refactoring, and code intelligence.

  Follows the same async pattern as completion: sends a request via
  `Client.request/3`, stores the reference in `state.workspace.lsp_pending`, and
  processes the response when it arrives in `Editor.handle_info`.

  Supported LSP methods:
  - textDocument/definition (go to definition)
  - textDocument/hover (hover documentation)
  - textDocument/references (find all references)
  - textDocument/documentHighlight (highlight symbol occurrences)
  - textDocument/codeAction (quickfix and refactor)
  - textDocument/rename (rename symbol)
  - textDocument/prepareRename (validate rename position)
  - textDocument/typeDefinition (go to type definition)
  - textDocument/implementation (go to implementation)
  - textDocument/documentSymbol (document outline)
  - workspace/symbol (project-wide symbol search)
  - textDocument/selectionRange (smart expand/shrink selection)
  - callHierarchy/incomingCalls + outgoingCalls
  - textDocument/codeLens (inline code annotations)
  - textDocument/inlayHint (inline type hints)
  """

  alias Minga.Buffer
  alias Minga.Editor.Commands
  alias Minga.Editor.HoverPopup
  alias Minga.Editor.LspDecorations
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.LSP, as: LSPState
  alias Minga.Editor.VimState
  alias Minga.Log
  alias Minga.Workspace.State, as: WorkspaceState
  alias Minga.LSP.Client
  alias Minga.LSP.DocumentHighlight
  alias Minga.LSP.SyncServer
  alias Minga.LSP.WorkspaceEdit
  alias Minga.Mode.CommandState
  alias Minga.Mode.VisualState
  alias Minga.UI.Picker.LocationSource

  @type state :: EditorState.t()

  @highlight_debounce_ms 150

  # ── Request senders ────────────────────────────────────────────────────────

  @doc "Sends a textDocument/definition request for the symbol under the cursor."
  @spec goto_definition(state()) :: state()
  def goto_definition(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def goto_definition(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        send_lsp_request(state, client, buf, "textDocument/definition", :definition)
    end
  end

  @doc "Sends a textDocument/hover request for the symbol under the cursor."
  @spec hover(state()) :: state()
  def hover(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def hover(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        send_lsp_request(state, client, buf, "textDocument/hover", :hover)
    end
  end

  # ── Find references ─────────────────────────────────────────────────────────

  @doc "Sends a textDocument/references request for the symbol under the cursor."
  @spec find_references(state()) :: state()
  def find_references(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def find_references(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        file_path = Buffer.file_path(buf)

        case file_path do
          nil ->
            EditorState.set_status(state, "Buffer has no file path")

          path ->
            uri = SyncServer.path_to_uri(path)
            {line, col} = Buffer.cursor(buf)

            params = %{
              "textDocument" => %{"uri" => uri},
              "position" => %{"line" => line, "character" => col},
              "context" => %{"includeDeclaration" => true}
            }

            ref = Client.request(client, "textDocument/references", params)

            put_in(
              state.workspace.lsp_pending,
              Map.put(state.workspace.lsp_pending, ref, :references)
            )
        end
    end
  end

  # ── Document highlight ────────────────────────────────────────────────────

  @doc """
  Sends a textDocument/documentHighlight request for the symbol under the cursor.

  Called on a debounce timer after cursor movement. Results are stored in
  `state.workspace.document_highlights` for the render pipeline to consume.
  """
  @spec document_highlight(state()) :: state()
  def document_highlight(%{workspace: %{buffers: %{active: nil}}} = state), do: state

  def document_highlight(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        state

      client ->
        send_lsp_request(
          state,
          client,
          buf,
          "textDocument/documentHighlight",
          :document_highlight
        )
    end
  end

  @doc """
  Schedules a debounced document highlight request.

  Cancels any pending highlight timer and starts a new one. Called on
  cursor movement in normal mode.
  """
  @spec schedule_document_highlight(state()) :: state()
  def schedule_document_highlight(%{workspace: %{buffers: %{active: nil}}} = state), do: state

  def schedule_document_highlight(state) do
    # Cancel any pending timer
    state = cancel_highlight_timer(state)

    # Only schedule if there's an LSP client available
    case lsp_client_for(state, state.workspace.buffers.active) do
      nil ->
        state

      _client ->
        timer = Process.send_after(self(), :document_highlight_debounce, @highlight_debounce_ms)
        %{state | lsp: LSPState.set_highlight_timer(state.lsp, timer)}
    end
  end

  @doc "Cancels the debounce timer and clears highlights."
  @spec clear_document_highlights(state()) :: state()
  def clear_document_highlights(state) do
    state
    |> cancel_highlight_timer()
    |> then(fn s -> put_in(s.workspace.document_highlights, nil) end)
  end

  @spec cancel_highlight_timer(state()) :: state()
  defp cancel_highlight_timer(state) do
    %{state | lsp: LSPState.cancel_highlight_timer(state.lsp)}
  end

  # ── Code actions ──────────────────────────────────────────────────────────

  @doc "Sends a textDocument/codeAction request for the cursor position."
  @spec code_action(state()) :: state()
  def code_action(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def code_action(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        file_path = Buffer.file_path(buf)

        case file_path do
          nil ->
            EditorState.set_status(state, "Buffer has no file path")

          path ->
            uri = SyncServer.path_to_uri(path)
            {line, col} = Buffer.cursor(buf)

            # Build the range (cursor position for point actions, or selection for visual mode)
            range = build_action_range(state, buf, line, col)
            diagnostics = diagnostics_at_range(uri, range)

            params = %{
              "textDocument" => %{"uri" => uri},
              "range" => range,
              "context" => %{
                "diagnostics" => diagnostics,
                "only" => nil
              }
            }

            ref = Client.request(client, "textDocument/codeAction", params)

            put_in(
              state.workspace.lsp_pending,
              Map.put(state.workspace.lsp_pending, ref, :code_action)
            )
        end
    end
  end

  # ── Rename ────────────────────────────────────────────────────────────────

  @doc "Sends a textDocument/prepareRename request to validate the rename position."
  @spec prepare_rename(state()) :: state()
  def prepare_rename(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def prepare_rename(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        send_lsp_request(state, client, buf, "textDocument/prepareRename", :prepare_rename)
    end
  end

  @doc "Sends a textDocument/rename request with the given new name."
  @spec rename(state(), String.t()) :: state()
  def rename(%{workspace: %{buffers: %{active: nil}}} = state, _new_name) do
    EditorState.set_status(state, "No active buffer")
  end

  def rename(%{workspace: %{buffers: %{active: buf}}} = state, new_name) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        file_path = Buffer.file_path(buf)

        case file_path do
          nil ->
            EditorState.set_status(state, "Buffer has no file path")

          path ->
            uri = SyncServer.path_to_uri(path)
            {line, col} = Buffer.cursor(buf)

            params = %{
              "textDocument" => %{"uri" => uri},
              "position" => %{"line" => line, "character" => col},
              "newName" => new_name
            }

            ref = Client.request(client, "textDocument/rename", params)

            put_in(
              state.workspace.lsp_pending,
              Map.put(state.workspace.lsp_pending, ref, :rename)
            )
        end
    end
  end

  # ── Type definition / Implementation ──────────────────────────────────────

  @doc "Sends a textDocument/typeDefinition request."
  @spec goto_type_definition(state()) :: state()
  def goto_type_definition(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def goto_type_definition(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        send_lsp_request(state, client, buf, "textDocument/typeDefinition", :type_definition)
    end
  end

  @doc "Sends a textDocument/implementation request."
  @spec goto_implementation(state()) :: state()
  def goto_implementation(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def goto_implementation(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        send_lsp_request(state, client, buf, "textDocument/implementation", :implementation)
    end
  end

  # ── Document symbols ──────────────────────────────────────────────────────

  @doc "Sends a textDocument/documentSymbol request."
  @spec document_symbols(state()) :: state()
  def document_symbols(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def document_symbols(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        file_path = Buffer.file_path(buf)

        case file_path do
          nil ->
            EditorState.set_status(state, "Buffer has no file path")

          path ->
            uri = SyncServer.path_to_uri(path)

            params = %{
              "textDocument" => %{"uri" => uri}
            }

            ref = Client.request(client, "textDocument/documentSymbol", params)

            put_in(
              state.workspace.lsp_pending,
              Map.put(state.workspace.lsp_pending, ref, :document_symbol)
            )
        end
    end
  end

  # ── Workspace symbols ─────────────────────────────────────────────────────

  @doc "Sends a workspace/symbol request with the given query."
  @spec workspace_symbols(state(), String.t()) :: state()
  def workspace_symbols(%{workspace: %{buffers: %{active: nil}}} = state, _query) do
    EditorState.set_status(state, "No active buffer")
  end

  def workspace_symbols(%{workspace: %{buffers: %{active: buf}}} = state, query) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        params = %{"query" => query}
        ref = Client.request(client, "workspace/symbol", params)

        put_in(
          state.workspace.lsp_pending,
          Map.put(state.workspace.lsp_pending, ref, :workspace_symbol)
        )
    end
  end

  # ── Selection range ───────────────────────────────────────────────────────

  @doc "Sends a textDocument/selectionRange request."
  @spec selection_range(state()) :: state()
  def selection_range(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def selection_range(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        file_path = Buffer.file_path(buf)

        case file_path do
          nil ->
            EditorState.set_status(state, "Buffer has no file path")

          path ->
            uri = SyncServer.path_to_uri(path)
            {line, col} = Buffer.cursor(buf)

            params = %{
              "textDocument" => %{"uri" => uri},
              "positions" => [%{"line" => line, "character" => col}]
            }

            ref = Client.request(client, "textDocument/selectionRange", params)

            put_in(
              state.workspace.lsp_pending,
              Map.put(state.workspace.lsp_pending, ref, :selection_range)
            )
        end
    end
  end

  @doc """
  Expands or initiates smart selection.

  If a selection range chain is already stored (from a previous expand),
  moves to the next wider range. Otherwise, sends a new selectionRange
  request to the LSP server.
  """
  @spec selection_expand(state()) :: state()
  def selection_expand(%{lsp: %{selection_ranges: ranges, selection_range_index: idx}} = state)
      when is_list(ranges) and idx + 1 < length(ranges) do
    new_idx = idx + 1
    range = Enum.at(ranges, new_idx)
    state = %{state | lsp: LSPState.expand_selection(state.lsp)}
    apply_selection_range(state, range)
  end

  def selection_expand(state) do
    # No stored ranges or at the widest range; send a new LSP request
    selection_range(state)
  end

  @doc """
  Shrinks the smart selection to the previous (narrower) range.

  Walks back down the stored selection range chain. If already at the
  innermost range, exits visual mode.
  """
  @spec selection_shrink(state()) :: state()
  def selection_shrink(%{lsp: %{selection_ranges: ranges, selection_range_index: idx}} = state)
      when is_list(ranges) and idx > 0 do
    new_idx = idx - 1
    range = Enum.at(ranges, new_idx)
    state = %{state | lsp: LSPState.shrink_selection(state.lsp)}
    apply_selection_range(state, range)
  end

  def selection_shrink(%{lsp: %{selection_ranges: [_ | _]}} = state) do
    # At innermost range, exit visual mode
    vim = VimState.transition(state.workspace.editing, :normal)

    %{
      EditorState.update_workspace(state, &WorkspaceState.set_editing(&1, vim))
      | lsp: LSPState.clear_selection_ranges(state.lsp)
    }
  end

  def selection_shrink(state) do
    EditorState.set_status(state, "No selection ranges to shrink")
  end

  # ── Call hierarchy ────────────────────────────────────────────────────────

  @doc "Sends a textDocument/prepareCallHierarchy request."
  @spec prepare_call_hierarchy(state()) :: state()
  def prepare_call_hierarchy(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def prepare_call_hierarchy(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        send_lsp_request(
          state,
          client,
          buf,
          "textDocument/prepareCallHierarchy",
          :prepare_call_hierarchy
        )
    end
  end

  @doc "Sends a textDocument/prepareCallHierarchy request for outgoing calls."
  @spec prepare_outgoing_call_hierarchy(state()) :: state()
  def prepare_outgoing_call_hierarchy(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def prepare_outgoing_call_hierarchy(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        send_lsp_request(
          state,
          client,
          buf,
          "textDocument/prepareCallHierarchy",
          :prepare_outgoing_hierarchy
        )
    end
  end

  # ── Code lens ─────────────────────────────────────────────────────────────

  @doc "Sends a textDocument/codeLens request."
  @spec code_lens(state()) :: state()
  def code_lens(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def code_lens(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        state

      client ->
        file_path = Buffer.file_path(buf)

        case file_path do
          nil ->
            EditorState.set_status(state, "Buffer has no file path")

          path ->
            uri = SyncServer.path_to_uri(path)
            params = %{"textDocument" => %{"uri" => uri}}
            ref = Client.request(client, "textDocument/codeLens", params)

            put_in(
              state.workspace.lsp_pending,
              Map.put(state.workspace.lsp_pending, ref, :code_lens)
            )
        end
    end
  end

  # ── Inlay hints ───────────────────────────────────────────────────────────

  @doc "Sends a textDocument/inlayHint request for the visible range."
  @spec inlay_hints(state()) :: state()
  def inlay_hints(%{workspace: %{buffers: %{active: nil}}} = state) do
    EditorState.set_status(state, "No active buffer")
  end

  def inlay_hints(%{workspace: %{buffers: %{active: buf}}} = state) do
    case lsp_client_for(state, buf) do
      nil ->
        state

      client ->
        file_path = Buffer.file_path(buf)

        case file_path do
          nil ->
            state

          path ->
            uri = SyncServer.path_to_uri(path)
            vp = state.workspace.viewport

            params = %{
              "textDocument" => %{"uri" => uri},
              "range" => %{
                "start" => %{"line" => vp.top, "character" => 0},
                "end" => %{"line" => vp.top + vp.rows, "character" => 0}
              }
            }

            ref = Client.request(client, "textDocument/inlayHint", params)

            put_in(
              state.workspace.lsp_pending,
              Map.put(state.workspace.lsp_pending, ref, :inlay_hint)
            )
        end
    end
  end

  @inlay_hint_scroll_debounce_ms 200

  @doc """
  Schedules a debounced inlay hint request when the viewport scrolls.

  Only fires the request if the viewport top has actually changed since
  the last inlay hint request. Debounced at 200ms to avoid flooding
  during rapid scrolling.
  """
  @spec schedule_inlay_hints_on_scroll(state()) :: state()
  def schedule_inlay_hints_on_scroll(%{workspace: %{buffers: %{active: nil}}} = state), do: state

  def schedule_inlay_hints_on_scroll(state) do
    vp_top = effective_viewport_top(state)

    if vp_top == state.lsp.last_inlay_viewport_top do
      state
    else
      # Cancel any pending timer
      state = cancel_inlay_hint_timer(state)

      timer =
        Process.send_after(self(), :inlay_hint_scroll_debounce, @inlay_hint_scroll_debounce_ms)

      %{state | lsp: LSPState.set_inlay_hint_timer(state.lsp, timer, vp_top)}
    end
  end

  @spec cancel_inlay_hint_timer(state()) :: state()
  defp cancel_inlay_hint_timer(state) do
    %{state | lsp: LSPState.cancel_inlay_hint_timer(state.lsp)}
  end

  # Returns the viewport top for the active window, falling back to
  # state.workspace.viewport.top. Uses EditorState.active_window_viewport when
  # the state is a proper struct, otherwise reads state.workspace.viewport directly.
  @spec effective_viewport_top(state()) :: non_neg_integer()
  defp effective_viewport_top(%EditorState{} = state) do
    EditorState.active_window_viewport(state).top
  end

  defp effective_viewport_top(state), do: state.workspace.viewport.top

  # ── Response handlers ──────────────────────────────────────────────────────

  @doc """
  Handles a textDocument/definition response.

  Parses Location or LocationLink results and navigates to the target.
  Sets the `'` mark before jumping so `''` returns to the previous position.
  """
  @spec handle_definition_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_definition_response(state, {:error, error}) do
    Log.debug(:lsp, "Definition request failed: #{inspect(error)}")
    EditorState.set_status(state, "Definition request failed")
  end

  def handle_definition_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No definition found")
  end

  def handle_definition_response(state, {:ok, []}) do
    EditorState.set_status(state, "No definition found")
  end

  def handle_definition_response(state, {:ok, result}) do
    case parse_location(result) do
      nil ->
        EditorState.set_status(state, "No definition found")

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
    Log.debug(:lsp, "Hover request failed: #{inspect(error)}")
    EditorState.set_status(state, "Hover request failed")
  end

  def handle_hover_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No hover information")
  end

  def handle_hover_response(state, {:ok, %{"contents" => contents}}) do
    markdown = extract_hover_markdown(contents)

    case markdown do
      "" ->
        EditorState.set_status(state, "No hover information")

      text ->
        {cursor_row, cursor_col} = hover_cursor_screen_position(state)
        popup = HoverPopup.new(text, cursor_row, cursor_col)
        Minga.Editor.State.set_hover_popup(state, popup)
    end
  end

  def handle_hover_response(state, {:ok, _}) do
    EditorState.set_status(state, "No hover information")
  end

  @doc """
  Handles a hover response for a mouse-position hover request.

  Creates a floating hover popup anchored at the mouse screen position
  (row, col) rather than the keyboard cursor position.
  """
  @spec handle_hover_mouse_response(
          state(),
          {:ok, term()} | {:error, term()},
          non_neg_integer(),
          non_neg_integer()
        ) :: state()
  def handle_hover_mouse_response(state, {:error, _}, _row, _col), do: state
  def handle_hover_mouse_response(state, {:ok, nil}, _row, _col), do: state

  def handle_hover_mouse_response(state, {:ok, %{"contents" => contents}}, row, col) do
    markdown = extract_hover_markdown(contents)

    case markdown do
      "" ->
        state

      text ->
        popup = HoverPopup.new(text, row, col)
        Minga.Editor.State.set_hover_popup(state, popup)
    end
  end

  def handle_hover_mouse_response(state, {:ok, _}, _row, _col), do: state

  # ── References response ─────────────────────────────────────────────────────

  @doc """
  Handles a textDocument/references response.

  If a single reference is found, jumps directly. If multiple, opens a
  location picker. If none, shows a status message.
  """
  @spec handle_references_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_references_response(state, {:error, error}) do
    Log.debug(:lsp, "References request failed: #{inspect(error)}")
    EditorState.set_status(state, "References request failed")
  end

  def handle_references_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No references found")
  end

  def handle_references_response(state, {:ok, []}) do
    EditorState.set_status(state, "No references found")
  end

  def handle_references_response(state, {:ok, [single]}) do
    case parse_single_location(single) do
      nil -> EditorState.set_status(state, "No references found")
      {uri, line, col} -> jump_to_location(state, uri, line, col)
    end
  end

  def handle_references_response(state, {:ok, locations}) when is_list(locations) do
    items = locations_to_picker_items(locations)

    case items do
      [] ->
        EditorState.set_status(state, "No references found")

      _ ->
        PickerUI.open(state, LocationSource, %{
          locations: items,
          title: "References (#{length(items)})"
        })
    end
  end

  # ── Document highlight response ───────────────────────────────────────────

  @doc """
  Handles a textDocument/documentHighlight response.

  Stores the highlight ranges in `state.workspace.document_highlights` for the
  render pipeline to consume.
  """
  @spec handle_document_highlight_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_document_highlight_response(state, {:error, _error}) do
    EditorState.update_workspace(state, &WorkspaceState.set_document_highlights(&1, nil))
  end

  def handle_document_highlight_response(state, {:ok, nil}) do
    EditorState.update_workspace(state, &WorkspaceState.set_document_highlights(&1, nil))
  end

  def handle_document_highlight_response(state, {:ok, []}) do
    EditorState.update_workspace(state, &WorkspaceState.set_document_highlights(&1, nil))
  end

  def handle_document_highlight_response(state, {:ok, highlights}) when is_list(highlights) do
    parsed = Enum.map(highlights, &DocumentHighlight.from_lsp/1)
    EditorState.update_workspace(state, &WorkspaceState.set_document_highlights(&1, parsed))
  end

  # ── Code action response ──────────────────────────────────────────────────

  @doc """
  Handles a textDocument/codeAction response.

  Opens a picker with available code actions. Selecting an action applies
  its workspace edit or executes its command.
  """
  @spec handle_code_action_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_code_action_response(state, {:error, error}) do
    Log.debug(:lsp, "Code action request failed: #{inspect(error)}")
    EditorState.set_status(state, "Code action request failed")
  end

  def handle_code_action_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No code actions available")
  end

  def handle_code_action_response(state, {:ok, []}) do
    EditorState.set_status(state, "No code actions available")
  end

  def handle_code_action_response(state, {:ok, actions}) when is_list(actions) do
    PickerUI.open(state, Minga.UI.Picker.CodeActionSource, %{actions: actions})
  end

  # ── Rename response ───────────────────────────────────────────────────────

  @doc """
  Handles a textDocument/prepareRename response.

  If the server confirms the position is renameable, enters command mode
  with the current symbol name pre-filled for the user to edit.
  """
  @spec handle_prepare_rename_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_prepare_rename_response(state, {:error, error}) do
    Log.debug(:lsp, "Prepare rename failed: #{inspect(error)}")
    EditorState.set_status(state, "Cannot rename at this position")
  end

  def handle_prepare_rename_response(state, {:ok, nil}) do
    EditorState.set_status(state, "Cannot rename at this position")
  end

  def handle_prepare_rename_response(state, {:ok, result}) do
    placeholder = extract_rename_placeholder(result, state)

    # Enter command mode with "rename <placeholder>" pre-filled
    # The ex-command parser handles "rename <new_name>" → {:rename, new_name}
    command_state = %CommandState{input: "rename #{placeholder}"}
    vim = VimState.transition(state.workspace.editing, :command, command_state)
    EditorState.update_workspace(state, &WorkspaceState.set_editing(&1, vim))
  end

  @doc """
  Handles a textDocument/rename response.

  Applies the returned WorkspaceEdit across all affected files.
  """
  @spec handle_rename_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_rename_response(state, {:error, error}) do
    Log.debug(:lsp, "Rename failed: #{inspect(error)}")
    EditorState.set_status(state, "Rename failed")
  end

  def handle_rename_response(state, {:ok, nil}) do
    EditorState.set_status(state, "Rename returned no edits")
  end

  def handle_rename_response(state, {:ok, workspace_edit}) do
    apply_workspace_edit(state, workspace_edit, "Rename")
  end

  # ── Type definition / Implementation responses ────────────────────────────

  @doc "Handles a textDocument/typeDefinition response (same format as definition)."
  @spec handle_type_definition_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_type_definition_response(state, {:error, error}) do
    Log.debug(:lsp, "Type definition request failed: #{inspect(error)}")
    EditorState.set_status(state, "Type definition request failed")
  end

  def handle_type_definition_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No type definition found")
  end

  def handle_type_definition_response(state, {:ok, []}) do
    EditorState.set_status(state, "No type definition found")
  end

  def handle_type_definition_response(state, {:ok, result}) do
    case parse_location(result) do
      nil -> EditorState.set_status(state, "No type definition found")
      {uri, line, col} -> jump_to_location(state, uri, line, col)
    end
  end

  @doc "Handles a textDocument/implementation response (same format as definition)."
  @spec handle_implementation_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_implementation_response(state, {:error, error}) do
    Log.debug(:lsp, "Implementation request failed: #{inspect(error)}")
    EditorState.set_status(state, "Implementation request failed")
  end

  def handle_implementation_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No implementation found")
  end

  def handle_implementation_response(state, {:ok, []}) do
    EditorState.set_status(state, "No implementation found")
  end

  def handle_implementation_response(state, {:ok, result}) do
    # Implementation can return multiple results
    case result do
      [single] ->
        case parse_single_location(single) do
          nil -> EditorState.set_status(state, "No implementation found")
          {uri, line, col} -> jump_to_location(state, uri, line, col)
        end

      locations when is_list(locations) ->
        items = locations_to_picker_items(locations)
        PickerUI.open(state, LocationSource, %{locations: items, title: "Implementations"})

      single when is_map(single) ->
        case parse_single_location(single) do
          nil -> EditorState.set_status(state, "No implementation found")
          {uri, line, col} -> jump_to_location(state, uri, line, col)
        end
    end
  end

  # ── Document symbol response ──────────────────────────────────────────────

  @doc "Handles a textDocument/documentSymbol response."
  @spec handle_document_symbol_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_document_symbol_response(state, {:error, error}) do
    Log.debug(:lsp, "Document symbol request failed: #{inspect(error)}")
    EditorState.set_status(state, "Document symbol request failed")
  end

  def handle_document_symbol_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No symbols found")
  end

  def handle_document_symbol_response(state, {:ok, []}) do
    EditorState.set_status(state, "No symbols found")
  end

  def handle_document_symbol_response(state, {:ok, symbols}) when is_list(symbols) do
    items = flatten_document_symbols(symbols, 0)

    case items do
      [] ->
        EditorState.set_status(state, "No symbols found")

      _ ->
        PickerUI.open(state, LocationSource, %{
          locations: items,
          title: "Document Symbols (#{length(items)})"
        })
    end
  end

  # ── Workspace symbol response ─────────────────────────────────────────────

  @doc "Handles a workspace/symbol response."
  @spec handle_workspace_symbol_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_workspace_symbol_response(state, {:error, error}) do
    Log.debug(:lsp, "Workspace symbol request failed: #{inspect(error)}")
    EditorState.set_status(state, "Workspace symbol request failed")
  end

  def handle_workspace_symbol_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No symbols found")
  end

  def handle_workspace_symbol_response(state, {:ok, []}) do
    EditorState.set_status(state, "No symbols found")
  end

  def handle_workspace_symbol_response(state, {:ok, symbols}) when is_list(symbols) do
    items = Enum.map(symbols, &workspace_symbol_to_location/1)

    case items do
      [] ->
        EditorState.set_status(state, "No symbols found")

      _ ->
        PickerUI.open(state, LocationSource, %{
          locations: items,
          title: "Workspace Symbols (#{length(items)})"
        })
    end
  end

  # ── Selection range response ──────────────────────────────────────────────

  @doc """
  Handles a textDocument/selectionRange response.

  Stores the selection range tree in state for expand/shrink navigation.
  Immediately expands to the first range.
  """
  @spec handle_selection_range_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_selection_range_response(state, {:error, error}) do
    Log.debug(:lsp, "Selection range request failed: #{inspect(error)}")
    EditorState.set_status(state, "Selection range request failed")
  end

  def handle_selection_range_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No selection ranges available")
  end

  def handle_selection_range_response(state, {:ok, []}) do
    EditorState.set_status(state, "No selection ranges available")
  end

  def handle_selection_range_response(state, {:ok, [range | _]}) do
    # Parse the nested selection range structure and apply the first expansion
    ranges = flatten_selection_ranges(range)

    case ranges do
      [] ->
        EditorState.set_status(state, "No selection ranges available")

      [first | _] ->
        # Store the range chain for subsequent expand/shrink operations
        state = %{state | lsp: LSPState.set_selection_ranges(state.lsp, ranges)}
        apply_selection_range(state, first)
    end
  end

  # ── Call hierarchy response ───────────────────────────────────────────────

  @doc "Handles a textDocument/prepareCallHierarchy response."
  @spec handle_prepare_call_hierarchy_response(state(), {:ok, term()} | {:error, term()}) ::
          state()
  def handle_prepare_call_hierarchy_response(state, {:error, error}) do
    Log.debug(:lsp, "Call hierarchy request failed: #{inspect(error)}")
    EditorState.set_status(state, "Call hierarchy request failed")
  end

  def handle_prepare_call_hierarchy_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No call hierarchy available")
  end

  def handle_prepare_call_hierarchy_response(state, {:ok, []}) do
    EditorState.set_status(state, "No call hierarchy available")
  end

  def handle_prepare_call_hierarchy_response(state, {:ok, [item | _]}) do
    # Store the call hierarchy item and request incoming calls
    request_incoming_calls(state, item)
  end

  @doc "Handles a prepareCallHierarchy response for outgoing calls."
  @spec handle_prepare_outgoing_hierarchy_response(state(), {:ok, term()} | {:error, term()}) ::
          state()
  def handle_prepare_outgoing_hierarchy_response(state, {:error, error}) do
    Log.debug(:lsp, "Call hierarchy request failed: #{inspect(error)}")
    EditorState.set_status(state, "Call hierarchy request failed")
  end

  def handle_prepare_outgoing_hierarchy_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No call hierarchy available")
  end

  def handle_prepare_outgoing_hierarchy_response(state, {:ok, []}) do
    EditorState.set_status(state, "No call hierarchy available")
  end

  def handle_prepare_outgoing_hierarchy_response(state, {:ok, [item | _]}) do
    request_outgoing_calls(state, item)
  end

  @doc "Handles a callHierarchy/incomingCalls response."
  @spec handle_incoming_calls_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_incoming_calls_response(state, {:error, _}) do
    EditorState.set_status(state, "Failed to fetch incoming calls")
  end

  def handle_incoming_calls_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No incoming calls")
  end

  def handle_incoming_calls_response(state, {:ok, []}) do
    EditorState.set_status(state, "No incoming calls")
  end

  def handle_incoming_calls_response(state, {:ok, calls}) when is_list(calls) do
    items =
      Enum.map(calls, fn call ->
        from = call["from"]
        uri = from["uri"]
        range = from["range"]
        {line, col} = extract_position(range["start"])
        path = SyncServer.uri_to_path(uri)
        name = from["name"]
        detail = Map.get(from, "detail", "")
        label = if detail != "", do: "#{name} (#{detail})", else: name
        {path, line, col, label}
      end)

    PickerUI.open(state, LocationSource, %{locations: items, title: "Incoming Calls"})
  end

  @doc "Handles a callHierarchy/outgoingCalls response."
  @spec handle_outgoing_calls_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_outgoing_calls_response(state, {:error, _}) do
    EditorState.set_status(state, "Failed to fetch outgoing calls")
  end

  def handle_outgoing_calls_response(state, {:ok, nil}) do
    EditorState.set_status(state, "No outgoing calls")
  end

  def handle_outgoing_calls_response(state, {:ok, []}) do
    EditorState.set_status(state, "No outgoing calls")
  end

  def handle_outgoing_calls_response(state, {:ok, calls}) when is_list(calls) do
    items =
      Enum.map(calls, fn call ->
        to = call["to"]
        uri = to["uri"]
        range = to["range"]
        {line, col} = extract_position(range["start"])
        path = SyncServer.uri_to_path(uri)
        name = to["name"]
        detail = Map.get(to, "detail", "")
        label = if detail != "", do: "#{name} (#{detail})", else: name
        {path, line, col, label}
      end)

    PickerUI.open(state, LocationSource, %{locations: items, title: "Outgoing Calls"})
  end

  # ── Code lens response ────────────────────────────────────────────────────

  @doc "Handles a textDocument/codeLens response (stores for rendering)."
  @spec handle_code_lens_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_code_lens_response(state, {:error, _}) do
    Log.debug(:lsp, "Code lens request failed")
    state
  end

  def handle_code_lens_response(state, {:ok, nil}), do: state
  def handle_code_lens_response(state, {:ok, []}), do: state

  def handle_code_lens_response(state, {:ok, lenses}) when is_list(lenses) do
    # Separate resolved lenses (have command) from unresolved ones (need codeLens/resolve)
    {resolved, unresolved} =
      Enum.split_with(lenses, fn lens -> lens["command"] != nil end)

    # Send resolve requests for lenses that have no command
    state = resolve_code_lenses(state, unresolved)

    # Store resolved lenses for rendering
    parsed =
      Enum.map(resolved, fn lens ->
        range = lens["range"]
        {line, _col} = extract_position(range["start"])
        command = lens["command"]
        title = if command, do: command["title"], else: nil
        %{line: line, title: title, data: lens}
      end)
      |> Enum.filter(fn l -> l.title != nil end)

    state = %{state | lsp: LSPState.set_code_lenses(state.lsp, parsed)}
    LspDecorations.apply_code_lenses(state)
  end

  # ── Inlay hint response ──────────────────────────────────────────────────

  @doc "Handles a textDocument/inlayHint response (stores for rendering)."
  @spec handle_inlay_hint_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_inlay_hint_response(state, {:error, _}) do
    Log.debug(:lsp, "Inlay hint request failed")
    state
  end

  def handle_inlay_hint_response(state, {:ok, nil}), do: state
  def handle_inlay_hint_response(state, {:ok, []}), do: state

  def handle_inlay_hint_response(state, {:ok, hints}) when is_list(hints) do
    parsed =
      Enum.map(hints, fn hint ->
        pos = hint["position"]
        label = extract_inlay_label(hint["label"])

        kind =
          case hint["kind"] do
            1 -> :type
            2 -> :parameter
            _ -> :other
          end

        %{
          line: pos["line"],
          col: pos["character"],
          label: label,
          kind: kind,
          padding_left: Map.get(hint, "paddingLeft", false),
          padding_right: Map.get(hint, "paddingRight", false)
        }
      end)

    state = %{state | lsp: LSPState.set_inlay_hints(state.lsp, parsed)}
    LspDecorations.apply_inlay_hints(state)
  end

  # ── WorkspaceEdit application ─────────────────────────────────────────────

  @doc """
  Applies a WorkspaceEdit to the editor, opening/modifying buffers as needed.

  Returns updated state with a status message indicating success or failure.
  """
  @spec apply_workspace_edit(state(), map(), String.t()) :: state()
  def apply_workspace_edit(state, workspace_edit, label) do
    file_edits = WorkspaceEdit.parse(workspace_edit)

    case file_edits do
      [] ->
        EditorState.set_status(state, "#{label}: no edits to apply")

      _ ->
        {state, file_count, edit_count} =
          Enum.reduce(file_edits, {state, 0, 0}, &apply_single_file_edit(&1, &2, label))

        EditorState.set_status(
          state,
          "#{label}: applied #{edit_count} edits across #{file_count} files"
        )
    end
  end

  @spec apply_single_file_edit(
          {String.t(), [WorkspaceEdit.text_edit()]},
          {state(), non_neg_integer(), non_neg_integer()},
          String.t()
        ) :: {state(), non_neg_integer(), non_neg_integer()}
  defp apply_single_file_edit({path, edits}, {st, fc, ec}, label) do
    st = ensure_buffer_open(st, path)

    case find_buffer_by_path(st, path) do
      nil ->
        Log.warning(:lsp, "#{label}: could not open buffer for #{path}")
        {st, fc, ec}

      pid ->
        Buffer.apply_edits(pid, edits)
        {st, fc + 1, ec + length(edits)}
    end
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
    file_path = Buffer.file_path(buffer_pid)

    case file_path do
      nil ->
        EditorState.set_status(state, "Buffer has no file path")

      path ->
        uri = SyncServer.path_to_uri(path)
        {line, col} = Buffer.cursor(buffer_pid)

        params = %{
          "textDocument" => %{"uri" => uri},
          "position" => %{"line" => line, "character" => col}
        }

        ref = Client.request(client, method, params)
        put_in(state.workspace.lsp_pending, Map.put(state.workspace.lsp_pending, ref, kind))
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
    current_path = Buffer.file_path(state.workspace.buffers.active)

    # Set jump mark before navigating
    state = set_jump_mark(state)

    if target_path == current_path do
      # Same file: just move the cursor
      Buffer.move_to(state.workspace.buffers.active, {line, col})
      state
    else
      # Different file: open it, then move cursor
      state = open_or_switch_to_file(state, target_path)
      Buffer.move_to(state.workspace.buffers.active, {line, col})
      state
    end
  end

  @spec open_or_switch_to_file(state(), String.t()) :: state()
  defp open_or_switch_to_file(state, file_path) do
    # Check if already open
    idx =
      Enum.find_index(state.workspace.buffers.list, fn buf ->
        try do
          Buffer.file_path(buf) == file_path
        catch
          :exit, _ -> false
        end
      end)

    case idx do
      nil ->
        case Commands.start_buffer(file_path) do
          {:ok, pid} -> Commands.add_buffer(state, pid)
          {:error, _reason} -> EditorState.set_status(state, "Could not open #{file_path}")
        end

      i ->
        EditorState.switch_buffer(state, i)
    end
  end

  @spec set_jump_mark(state()) :: state()
  defp set_jump_mark(%{workspace: %{buffers: %{active: buf}}} = state) when is_pid(buf) do
    pos = Buffer.cursor(buf)

    EditorState.update_workspace(state, fn ws ->
      WorkspaceState.update_editing(ws, &VimState.set_last_jump_pos(&1, pos))
    end)
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
    buf = state.workspace.buffers.active

    if buf do
      {line, col} = Buffer.cursor(buf)
      # Approximate screen position: line offset from viewport top + gutter
      vp = state.workspace.viewport
      screen_row = line - vp.top + 1
      screen_col = col + 4
      {clamp(screen_row, 1, vp.rows - 2), clamp(screen_col, 0, vp.cols - 1)}
    else
      {div(state.workspace.viewport.rows, 2), div(state.workspace.viewport.cols, 2)}
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

  # ── Helpers for new LSP features ──────────────────────────────────────────

  @spec locations_to_picker_items([map()]) :: [
          {String.t(), non_neg_integer(), non_neg_integer(), String.t()}
        ]
  defp locations_to_picker_items(locations) do
    locations
    |> Enum.map(fn loc ->
      case parse_single_location(loc) do
        nil ->
          nil

        {uri, line, col} ->
          path = SyncServer.uri_to_path(uri)
          label = read_line_content(path, line)
          {path, line, col, label}
      end
    end)
    |> Enum.reject(&is_nil/1)
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

  @spec build_action_range(state(), pid(), non_neg_integer(), non_neg_integer()) :: map()
  defp build_action_range(state, _buf, line, col) do
    # If we're in visual mode, use the visual anchor
    case Minga.Editing.mode(state) do
      :visual ->
        anchor =
          case Minga.Editor.Editing.visual_anchor(state) do
            {al, ac} -> {al, ac}
            _ -> {line, col}
          end

        {anchor_line, anchor_col} = anchor

        %{
          "start" => %{
            "line" => min(anchor_line, line),
            "character" => min(anchor_col, col)
          },
          "end" => %{
            "line" => max(anchor_line, line),
            "character" => max(anchor_col, col)
          }
        }

      _ ->
        %{
          "start" => %{"line" => line, "character" => col},
          "end" => %{"line" => line, "character" => col}
        }
    end
  end

  @spec diagnostics_at_range(String.t(), map()) :: [map()]
  defp diagnostics_at_range(uri, range) do
    start_line = range["start"]["line"]
    end_line = range["end"]["line"]

    uri
    |> Minga.Diagnostics.for_uri()
    |> Enum.filter(fn diag ->
      diag.range.start_line >= start_line and diag.range.start_line <= end_line
    end)
    |> Enum.map(fn diag ->
      %{
        "range" => %{
          "start" => %{"line" => diag.range.start_line, "character" => diag.range.start_col},
          "end" => %{"line" => diag.range.end_line, "character" => diag.range.end_col}
        },
        "message" => diag.message,
        "severity" => severity_to_lsp(diag.severity)
      }
    end)
  end

  @spec severity_to_lsp(atom()) :: non_neg_integer()
  defp severity_to_lsp(:error), do: 1
  defp severity_to_lsp(:warning), do: 2
  defp severity_to_lsp(:info), do: 3
  defp severity_to_lsp(:hint), do: 4

  # Sends codeLens/resolve requests for lenses that have no command yet.
  @spec resolve_code_lenses(state(), [map()]) :: state()
  defp resolve_code_lenses(state, []), do: state

  defp resolve_code_lenses(state, unresolved) do
    buf = state.workspace.buffers.active

    case lsp_client_for(state, buf) do
      nil ->
        state

      client ->
        Enum.reduce(unresolved, state, fn lens, st ->
          ref = Client.request(client, "codeLens/resolve", lens)

          put_in(
            st.workspace.lsp_pending,
            Map.put(st.workspace.lsp_pending, ref, :code_lens_resolve)
          )
        end)
    end
  end

  @doc "Handles a codeLens/resolve response, merging the resolved lens into the existing list."
  @spec handle_code_lens_resolve_response(state(), {:ok, term()} | {:error, term()}) :: state()
  def handle_code_lens_resolve_response(state, {:error, _}) do
    Log.debug(:lsp, "Code lens resolve failed")
    state
  end

  def handle_code_lens_resolve_response(state, {:ok, nil}), do: state

  def handle_code_lens_resolve_response(state, {:ok, lens}) when is_map(lens) do
    command = lens["command"]

    case command do
      nil ->
        state

      %{"title" => title} ->
        range = lens["range"]
        {line, _col} = extract_position(range["start"])
        entry = %{line: line, title: title, data: lens}
        state = %{state | lsp: LSPState.append_code_lens(state.lsp, entry)}
        LspDecorations.apply_code_lenses(state)
    end
  end

  def handle_code_lens_resolve_response(state, {:ok, _}), do: state

  @spec extract_rename_placeholder(map(), state()) :: String.t()
  defp extract_rename_placeholder(%{"placeholder" => name}, _state) when is_binary(name),
    do: name

  defp extract_rename_placeholder(%{"range" => _, "placeholder" => name}, _state)
       when is_binary(name),
       do: name

  defp extract_rename_placeholder(
         %{
           "start" => %{"line" => sl, "character" => sc},
           "end" => %{"line" => el, "character" => ec}
         },
         state
       ) do
    # Server returned a Range without placeholder; read text from buffer
    read_range_from_buffer(state, {sl, sc}, {el, ec})
  end

  defp extract_rename_placeholder(
         %{
           "range" => %{
             "start" => %{"line" => sl, "character" => sc},
             "end" => %{"line" => el, "character" => ec}
           }
         },
         state
       ) do
    # Range wrapper without placeholder; read text from buffer
    read_range_from_buffer(state, {sl, sc}, {el, ec})
  end

  defp extract_rename_placeholder(_, _state), do: ""

  # Reads text from the buffer for an LSP range (end is exclusive).
  # content_range is inclusive on both ends, so we adjust end_col - 1.
  @spec read_range_from_buffer(
          state(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()}
        ) :: String.t()
  defp read_range_from_buffer(%{workspace: %{buffers: %{active: buf}}}, {sl, sc}, {el, ec})
       when is_pid(buf) do
    {adj_el, adj_ec} = adjust_lsp_end_position(buf, el, ec)
    Buffer.text_between(buf, {sl, sc}, {adj_el, adj_ec})
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  defp read_range_from_buffer(_, _, _), do: ""

  # LSP end position is exclusive. content_range is inclusive.
  # Adjust end position back by 1 column (or to end of prev line if col is 0).
  @spec adjust_lsp_end_position(pid(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp adjust_lsp_end_position(_buf, el, ec) when ec > 0, do: {el, ec - 1}

  defp adjust_lsp_end_position(buf, el, 0) when el > 0 do
    case Buffer.lines(buf, el - 1, 1) do
      [prev_line] -> {el - 1, byte_size(prev_line)}
      _ -> {el, 0}
    end
  end

  defp adjust_lsp_end_position(_buf, el, ec), do: {el, ec}

  @spec flatten_document_symbols([map()], non_neg_integer()) :: [
          {String.t(), non_neg_integer(), non_neg_integer(), String.t()}
        ]
  defp flatten_document_symbols(symbols, depth) do
    Enum.flat_map(symbols, fn sym ->
      range = sym["range"] || sym["location"]["range"]
      {line, col} = extract_position(range["start"])
      name = sym["name"]
      kind = symbol_kind_name(sym["kind"])
      indent = String.duplicate("  ", depth)
      label = "#{indent}#{kind} #{name}"

      # For DocumentSymbol format (hierarchical)
      path =
        case sym do
          %{"location" => %{"uri" => uri}} -> SyncServer.uri_to_path(uri)
          _ -> nil
        end

      # Use empty path for document symbols (same file)
      entry = {path || "", line, col, label}

      children = Map.get(sym, "children", [])
      [entry | flatten_document_symbols(children, depth + 1)]
    end)
  end

  @spec workspace_symbol_to_location(map()) ::
          {String.t(), non_neg_integer(), non_neg_integer(), String.t()}
  defp workspace_symbol_to_location(sym) do
    location = sym["location"]
    uri = location["uri"]
    range = location["range"]
    {line, col} = extract_position(range["start"])
    path = SyncServer.uri_to_path(uri)
    kind = symbol_kind_name(sym["kind"])
    container = Map.get(sym, "containerName", "")
    name = sym["name"]
    label = if container != "", do: "#{kind} #{container}.#{name}", else: "#{kind} #{name}"
    {path, line, col, label}
  end

  @spec symbol_kind_name(non_neg_integer() | nil) :: String.t()
  defp symbol_kind_name(1), do: "File"
  defp symbol_kind_name(2), do: "Module"
  defp symbol_kind_name(3), do: "Namespace"
  defp symbol_kind_name(4), do: "Package"
  defp symbol_kind_name(5), do: "Class"
  defp symbol_kind_name(6), do: "Method"
  defp symbol_kind_name(7), do: "Property"
  defp symbol_kind_name(8), do: "Field"
  defp symbol_kind_name(9), do: "Constructor"
  defp symbol_kind_name(10), do: "Enum"
  defp symbol_kind_name(11), do: "Interface"
  defp symbol_kind_name(12), do: "Function"
  defp symbol_kind_name(13), do: "Variable"
  defp symbol_kind_name(14), do: "Constant"
  defp symbol_kind_name(15), do: "String"
  defp symbol_kind_name(16), do: "Number"
  defp symbol_kind_name(17), do: "Boolean"
  defp symbol_kind_name(18), do: "Array"
  defp symbol_kind_name(19), do: "Object"
  defp symbol_kind_name(20), do: "Key"
  defp symbol_kind_name(21), do: "Null"
  defp symbol_kind_name(22), do: "EnumMember"
  defp symbol_kind_name(23), do: "Struct"
  defp symbol_kind_name(24), do: "Event"
  defp symbol_kind_name(25), do: "Operator"
  defp symbol_kind_name(26), do: "TypeParameter"
  defp symbol_kind_name(_), do: "Symbol"

  @spec flatten_selection_ranges(map()) :: [map()]
  defp flatten_selection_ranges(%{"range" => range} = sel) do
    entry = %{
      start_line: range["start"]["line"],
      start_col: range["start"]["character"],
      end_line: range["end"]["line"],
      end_col: range["end"]["character"]
    }

    case Map.get(sel, "parent") do
      nil -> [entry]
      parent -> [entry | flatten_selection_ranges(parent)]
    end
  end

  defp flatten_selection_ranges(_), do: []

  @spec apply_selection_range(state(), map()) :: state()
  defp apply_selection_range(state, range) do
    buf = state.workspace.buffers.active

    if buf do
      # Move cursor to the end of the range
      Buffer.move_to(buf, {range.end_line, range.end_col})

      # Enter visual mode with the anchor at the start of the range
      visual_state = %VisualState{
        visual_anchor: {range.start_line, range.start_col},
        visual_type: :char
      }

      vim = VimState.transition(state.workspace.editing, :visual, visual_state)
      EditorState.update_workspace(state, &WorkspaceState.set_editing(&1, vim))
    else
      state
    end
  end

  @spec request_incoming_calls(state(), map()) :: state()
  defp request_incoming_calls(state, item) do
    buf = state.workspace.buffers.active

    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        params = %{"item" => item}
        ref = Client.request(client, "callHierarchy/incomingCalls", params)

        put_in(
          state.workspace.lsp_pending,
          Map.put(state.workspace.lsp_pending, ref, :incoming_calls)
        )
    end
  end

  @spec request_outgoing_calls(state(), map()) :: state()
  defp request_outgoing_calls(state, item) do
    buf = state.workspace.buffers.active

    case lsp_client_for(state, buf) do
      nil ->
        EditorState.set_status(state, "No language server")

      client ->
        params = %{"item" => item}
        ref = Client.request(client, "callHierarchy/outgoingCalls", params)

        put_in(
          state.workspace.lsp_pending,
          Map.put(state.workspace.lsp_pending, ref, :outgoing_calls)
        )
    end
  end

  @spec extract_inlay_label(term()) :: String.t()
  defp extract_inlay_label(label) when is_binary(label), do: label

  defp extract_inlay_label(parts) when is_list(parts) do
    Enum.map_join(parts, fn
      %{"value" => v} when is_binary(v) -> v
      s when is_binary(s) -> s
      _ -> ""
    end)
  end

  defp extract_inlay_label(_), do: ""

  @spec ensure_buffer_open(state(), String.t()) :: state()
  defp ensure_buffer_open(state, path) do
    case find_buffer_by_path(state, path) do
      nil ->
        case Commands.start_buffer(path) do
          {:ok, pid} -> Commands.add_buffer(state, pid)
          {:error, _} -> state
        end

      _pid ->
        state
    end
  end

  @spec find_buffer_by_path(state(), String.t()) :: pid() | nil
  defp find_buffer_by_path(state, path) do
    Enum.find(state.workspace.buffers.list, fn buf ->
      try do
        Buffer.file_path(buf) == path
      catch
        :exit, _ -> false
      end
    end)
  end
end
