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
  a `workspace` field (a plain map, not a WorkspaceState struct) so those
  pattern-matches work unchanged. Top-level fields (`theme`, `capabilities`,
  `shell`, `shell_state`, etc.) are directly on Input, matching EditorState's
  shape.

  ## Field sources

  **From `state` (top-level):**
  `theme`, `capabilities`, `shell`, `shell_state`, `port_manager`,
  `font_registry`, `message_store`, `face_override_registries`,
  `editing_model`, `backend`, `layout`

  **From `state.workspace` (per-tab editing context, stored as `workspace` map):**
  `windows`, `buffers`, `viewport`, `file_tree`, `highlight`,
  `agent_ui`, `completion`, `editing`, `document_highlights`,
  `search`, `keymap_scope`
  """

  alias MingaEditor.Agent.UIState
  alias Minga.Editing.Completion
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
  alias MingaEditor.UI.FontRegistry
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
    :font_registry,
    :message_store,
    :face_override_registries,
    :editing_model,
    :backend,
    :layout,
    :lsp,
    :parser_status,
    # Workspace as a plain map (enables state.workspace.X pattern-matching)
    :workspace
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
          completion: Completion.t() | nil,
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
          face_override_registries: %{pid() => MingaEditor.UI.Face.Registry.t()},
          editing_model: :vim | :cua,
          backend: EditorState.backend(),
          layout: Layout.t() | nil,
          lsp: LSPState.t(),
          parser_status: atom(),
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
      font_registry: state.font_registry,
      message_store: state.message_store,
      face_override_registries: state.face_override_registries,
      editing_model: state.editing_model,
      backend: state.backend,
      layout: state.layout,
      lsp: state.lsp,
      parser_status: state.parser_status,
      workspace: %{
        windows: ws.windows,
        buffers: ws.buffers,
        viewport: ws.viewport,
        file_tree: ws.file_tree,
        highlight: ws.highlight,
        agent_ui: ws.agent_ui,
        completion: ws.completion,
        editing: ws.editing,
        document_highlights: ws.document_highlights,
        mouse: ws.mouse,
        search: ws.search,
        keymap_scope: ws.keymap_scope
      }
    }
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
