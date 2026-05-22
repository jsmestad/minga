defmodule MingaEditor.RenderPipeline.Input do
  @moduledoc """
  Narrow rendering contract between the Editor GenServer and the render pipeline.

  Bundles exactly the fields that the pipeline stages read from EditorState,
  excluding ~15 fields the pipeline never touches (render_timer, buffer_monitors,
  focus_stack, lsp, parser_status, pending_quit, session, git_remote_op, etc.).

  The Editor builds this before calling `RenderPipeline.run/1`. Pipeline stages
  read from Input and never reach back into EditorState. After the pipeline
  completes, the caller writes mutations back via `EditorState.apply_render_output/2`.

  ## Structural compatibility

  Pipeline modules pattern-match on `state.workspace.X` throughout. Input keeps
  a `workspace` field (a plain map, not a SessionState struct) so those
  pattern-matches work unchanged. Top-level fields (`theme`, `capabilities`,
  `shell`, `shell_state`, etc.) are directly on Input, matching EditorState's
  shape.

  ## Field sources

  **From `state` (top-level):**
  `theme`, `capabilities`, `shell`, `shell_state`, `port_manager`,
  `message_store`, `notifications`, `face_override_registries`,
  `editing_model`, `backend`, `layout`, `focus_tree`

  `font_registry` is renderer-owned state. Editor-created snapshots carry a
  fresh fallback registry; `Renderer.Server` injects its long-lived registry
  before it runs the pipeline.

  **From `state.workspace` (per-tab editing context, stored as `workspace` map):**
  `windows`, `buffers`, `viewport`, `file_tree`, `highlight`,
  `agent_ui`, `editing`, `document_highlights`,
  `search`, `keymap_scope`

  Note: completion lives on `state.shell_state.modal` after #1426; the
  fingerprint includes the modal sum type, so completion changes are
  picked up there.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Layout
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Mouse
  alias MingaEditor.State.Search
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.Shell.Board.State, as: BoardState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.NotificationCenter
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.UI.Theme

  @enforce_keys [:port_manager, :theme, :capabilities, :shell, :workspace]
  defstruct [
    # Top-level state fields
    :port_manager,
    :theme,
    :capabilities,
    :shell,
    :shell_state,
    :message_store,
    :notifications,
    :face_override_registries,
    :editing_model,
    :backend,
    :layout,
    :focus_tree,
    :lsp,
    :parser_status,
    :diff_views,
    # Workspace as a plain map (enables state.workspace.X pattern-matching)
    :workspace,
    # Terminal-level viewport (screen dimensions reported by frontend on resize)
    terminal_viewport: Viewport.new(24, 80),
    # Render-pipeline caches (replaces process-dictionary entries)
    caches: %Caches{},
    # Renderer-owned font registration state. Editor snapshots use a fresh
    # fallback; Renderer.Server replaces it with its persistent registry.
    font_registry: FontRegistry.new()
  ]

  @typedoc """
  Workspace-shaped map containing per-tab rendering fields.

  Keeps the same `state.workspace.X` access pattern that pipeline modules
  use, so existing pattern-matches work unchanged.
  """
  @type workspace :: %{
          windows: Windows.t(),
          buffers: Buffers.t(),
          viewport: Viewport.t(),
          file_tree: FileTree.t(),
          highlight: Highlighting.t(),
          agent_ui: UIState.t(),
          editing: VimState.t(),
          document_highlights: [EditorState.document_highlight()] | nil,
          mouse: Mouse.t(),
          search: Search.t(),
          keymap_scope: Minga.Keymap.Scope.scope_name()
        }

  @type t :: %__MODULE__{
          port_manager: GenServer.server() | nil,
          theme: Theme.t(),
          capabilities: Capabilities.t(),
          shell: module(),
          shell_state: ShellState.t() | BoardState.t(),
          font_registry: FontRegistry.t(),
          message_store: MessageStore.t(),
          notifications: NotificationCenter.t(),
          face_override_registries: %{pid() => MingaEditor.UI.Face.Registry.t()},
          editing_model: :vim | :cua,
          backend: EditorState.backend(),
          layout: Layout.t() | nil,
          focus_tree: MingaEditor.FocusTree.t() | nil,
          lsp: LSPState.t(),
          parser_status: atom(),
          diff_views: %{pid() => EditorState.diff_view_info()},
          caches: Caches.t(),
          terminal_viewport: Viewport.t(),
          workspace: workspace()
        }

  @doc """
  Builds a render pipeline Input from the full editor state.

  Extracts exactly the fields that the pipeline's seven stages read,
  leaving GenServer-only fields (render_timer, buffer_monitors,
  focus_stack, session, pending_quit, etc.) behind.
  """
  @spec from_editor_state(EditorState.t()) :: t()
  def from_editor_state(%EditorState{workspace: ws} = state) do
    %__MODULE__{
      port_manager: state.port_manager,
      theme: state.theme,
      capabilities: state.capabilities,
      shell: state.shell,
      shell_state: state.shell_state,
      message_store: state.message_store,
      notifications: state.notifications,
      face_override_registries: state.face_override_registries,
      editing_model: state.editing_model,
      backend: state.backend,
      layout: state.layout,
      focus_tree: state.focus_tree,
      lsp: state.lsp,
      parser_status: state.parser_status,
      diff_views: state.diff_views,
      caches: state.caches,
      terminal_viewport: state.terminal_viewport,
      workspace: %{
        windows: ws.windows,
        buffers: ws.buffers,
        viewport: ws.viewport,
        file_tree: ws.file_tree,
        highlight: ws.highlight,
        agent_ui: ws.agent_ui,
        editing: ws.editing,
        document_highlights: ws.document_highlights,
        mouse: ws.mouse,
        search: ws.search,
        keymap_scope: ws.keymap_scope
      }
    }
  end

  @doc "Returns a copy of the render input with the renderer-owned font registry attached."
  @spec with_font_registry(t(), FontRegistry.t()) :: t()
  def with_font_registry(%__MODULE__{} = input, %FontRegistry{} = font_registry) do
    %{input | font_registry: font_registry}
  end

  # ── Chrome dirty tracking ──────────────────────────────────────────────────

  @doc """
  Computes a fingerprint of chrome-relevant fields for dirty tracking.

  The chrome stage is expensive (tab bar, status bar, file tree, overlays).
  When the fingerprint matches the previous frame's, the chrome stage can
  reuse cached draws. The fingerprint covers all fields that affect chrome
  output; buffer content changes (which only affect the Content stage) do
  not change the fingerprint.

  Returns an integer hash suitable for fast equality comparison.
  """
  @spec chrome_fingerprint(t()) :: integer()
  def chrome_fingerprint(%__MODULE__{} = input) do
    buf = input.workspace.buffers.active
    chrome_fingerprint(input, buffer_fingerprint_data(buf))
  end

  @spec chrome_fingerprint(t(), map()) :: integer()
  def chrome_fingerprint(%__MODULE__{} = input, scrolls) when is_map(scrolls) do
    active = input.workspace.windows.active

    fingerprint_data =
      case Map.get(scrolls, active) do
        %{cursor_line: line, cursor_byte_col: col, buf_version: version} -> {{line, col}, version}
        _ -> buffer_fingerprint_data(input.workspace.buffers.active)
      end

    chrome_fingerprint(input, fingerprint_data)
  end

  @spec chrome_fingerprint(t(), {{non_neg_integer(), non_neg_integer()}, non_neg_integer()}) ::
          integer()
  def chrome_fingerprint(%__MODULE__{} = input, {buf_cursor, buf_version}) do
    # Hash the fields that drive chrome output. We use :erlang.phash2
    # for speed (no crypto needed, just change detection).
    #
    # Includes the active buffer identity, cursor, and version because the status
    # bar displays file name, filetype, cursor position, line count, and dirty state. The render
    # pipeline passes scroll-stage buffer data when available so this does
    # not need duplicate GenServer calls in the hot path.

    :erlang.phash2({
      # Buffer state for status bar (identity, cursor pos, version/dirty)
      input.workspace.buffers.active,
      buf_cursor,
      buf_version,
      # Theme affects status bar, tab bar, file tree, minibuffer, and overlay styling.
      input.theme,
      # Status bar metadata can change without a content version bump, such as save clearing dirty.
      status_bar_fingerprint(input),
      # Mode affects status bar label, minibuffer content, cursor shape
      input.workspace.editing.mode,
      input.workspace.editing.mode_state,
      # Tab bar state
      input.shell_state |> Map.get(:tab_bar),
      # Status message (flash messages in status bar)
      input.shell_state |> Map.get(:status_msg),
      # Nav flash overlay
      input.shell_state |> Map.get(:nav_flash),
      # File tree
      input.workspace.file_tree,
      # Hover popup and signature help
      input.shell_state |> Map.get(:hover_popup),
      input.shell_state |> Map.get(:signature_help),
      # Which-key popup
      input.shell_state |> Map.get(:whichkey),
      # Modal overlay (sum type covering picker, prompt, dashboard,
      # conflict, completion)
      input.shell_state |> Map.get(:modal),
      # Agent state (status, pending approval)
      input.shell_state |> Map.get(:agent),
      # Viewport dimensions (overlay positioning)
      input.terminal_viewport.rows,
      input.terminal_viewport.cols,
      # Window splits (separator rendering)
      input.workspace.windows.tree,
      # Bottom panel
      input.shell_state |> Map.get(:bottom_panel),
      # GUI notification center
      input.notifications,
      # Git status panel
      input.shell_state |> Map.get(:git_status_panel),
      # Shell-owned chrome state that does not belong in the generic pipeline contract
      input.shell.chrome_fingerprint(input)
    })
  end

  @spec status_bar_fingerprint(t()) :: integer()
  defp status_bar_fingerprint(%__MODULE__{} = input) do
    input
    |> StatusBarData.from_state()
    |> :erlang.phash2()
  catch
    :exit, _ -> 0
  end

  @spec buffer_fingerprint_data(pid() | nil) ::
          {{non_neg_integer(), non_neg_integer()}, non_neg_integer()}
  defp buffer_fingerprint_data(nil), do: {{0, 0}, 0}

  defp buffer_fingerprint_data(buf) when is_pid(buf) do
    {Minga.Buffer.cursor(buf), Minga.Buffer.version(buf)}
  catch
    :exit, _ -> {{0, 0}, 0}
  end

  @doc """
  Syncs the active window's cursor from the buffer process.

  Equivalent to `EditorState.sync_active_window_cursor/1` but operates
  on the Input's workspace map.
  """
  @spec sync_active_window_cursor(t()) :: t()
  def sync_active_window_cursor(%__MODULE__{workspace: %{buffers: %{active: nil}}} = input),
    do: input

  def sync_active_window_cursor(
        %__MODULE__{
          workspace: %{windows: %{map: windows, active: id}, buffers: %{active: buf}} = ws
        } = input
      ) do
    case Map.fetch(windows, id) do
      {:ok, window} ->
        cursor = Minga.Buffer.cursor(buf)
        new_map = Map.put(windows, id, %{window | cursor: cursor})
        %{input | workspace: %{ws | windows: %{ws.windows | map: new_map}}}

      :error ->
        input
    end
  catch
    :exit, _ -> input
  end
end
