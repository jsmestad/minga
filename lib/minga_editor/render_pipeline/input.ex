defmodule MingaEditor.RenderPipeline.Input do
  @moduledoc """
  Narrow rendering contract between the Editor GenServer and the render pipeline.

  Bundles exactly the fields that the pipeline stages read from EditorState,
  excluding ~15 fields the pipeline never touches (render_timer, buffer_monitors,
  focus_stack, lsp, parser_status, pending_quit, session, git_remote_op, etc.).

  The Editor builds this before calling `RenderPipeline.run/1`. Pipeline stages
  read from Input and never reach back into EditorState. Mutations that stages
  need to carry forward (updated window caches, click regions) are returned via
  `RenderPipeline.Output`.

  ## Field sources

  Fields are grouped by where they come from in EditorState:

  **From `state` (top-level):**
  - `theme`, `capabilities`, `shell`, `shell_state`, `port_manager`,
    `font_registry`, `message_store`, `face_override_registries`,
    `editing_model`, `backend`, `layout`

  **From `state.workspace` (per-tab editing context):**
  - `windows`, `buffers`, `viewport`, `file_tree`, `highlight`,
    `agent_ui`, `completion`, `editing`, `document_highlights`,
    `search`, `keymap_scope`
  """

  alias MingaEditor.Agent.UIState
  alias Minga.Editing.Completion
  alias MingaEditor.Layout
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Search
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.Shell.Board.State, as: BoardState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.UI.Theme

  @enforce_keys [:port_manager, :theme, :capabilities, :shell, :windows, :viewport]
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
    # Workspace fields
    :windows,
    :buffers,
    :viewport,
    :file_tree,
    :highlight,
    :agent_ui,
    :completion,
    :editing,
    :document_highlights,
    :search,
    :keymap_scope
  ]

  @type t :: %__MODULE__{
          # Top-level state fields
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
          # Workspace fields
          windows: Windows.t(),
          buffers: Buffers.t(),
          viewport: Viewport.t(),
          file_tree: FileTree.t(),
          highlight: Highlighting.t(),
          agent_ui: UIState.t(),
          completion: Completion.t() | nil,
          editing: VimState.t(),
          document_highlights: [EditorState.document_highlight()] | nil,
          search: Search.t(),
          keymap_scope: Minga.Keymap.Scope.scope_name()
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
      # Top-level
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
      # Workspace
      windows: ws.windows,
      buffers: ws.buffers,
      viewport: ws.viewport,
      file_tree: ws.file_tree,
      highlight: ws.highlight,
      agent_ui: ws.agent_ui,
      completion: ws.completion,
      editing: ws.editing,
      document_highlights: ws.document_highlights,
      search: ws.search,
      keymap_scope: ws.keymap_scope
    }
  end

  # ── Workspace-shaped accessors ───────────────────────────────────────────
  #
  # Many pipeline modules pattern-match on `state.workspace.X`. These
  # accessors let Input masquerade as EditorState for pattern matching
  # during the transition period (PR A-4.2 will update call sites to
  # use Input fields directly).

  @doc """
  Returns a workspace-shaped map for backward compatibility.

  Pipeline modules that pattern-match on `state.workspace.X` can use
  `input.workspace.X` during the transition. This is a temporary shim;
  PR A-4.2 will update call sites to read from Input directly.
  """
  @spec workspace(t()) :: map()
  def workspace(%__MODULE__{} = input) do
    %{
      windows: input.windows,
      buffers: input.buffers,
      viewport: input.viewport,
      file_tree: input.file_tree,
      highlight: input.highlight,
      agent_ui: input.agent_ui,
      completion: input.completion,
      editing: input.editing,
      document_highlights: input.document_highlights,
      search: input.search,
      keymap_scope: input.keymap_scope
    }
  end
end
