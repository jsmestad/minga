defmodule Minga.Workspace.State do
  @moduledoc """
  Core editing context that exists regardless of presentation.

  A workspace is the unit of state that gets saved and restored when
  switching tabs. It contains everything needed to edit: buffers,
  windows, vim/editing state, search, completion, highlights, and
  other per-document context. It does NOT contain presentation
  concerns like tab bars, file trees, pickers, or chrome state.

  This struct formalizes the boundary that `@per_tab_fields` in
  `Minga.Editor.State` previously defined implicitly.
  """

  alias Minga.Agent.UIState
  alias Minga.Completion
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.State.Mouse
  alias Minga.Editor.State.Search
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState

  @enforce_keys [:viewport]
  defstruct vim: VimState.new(),
            buffers: %Buffers{},
            windows: %Windows{},
            file_tree: %FileTreeState{},
            viewport: nil,
            mouse: %Mouse{},
            highlight: %Highlighting{},
            lsp_pending: %{},
            completion: nil,
            completion_trigger: CompletionTrigger.new(),
            injection_ranges: %{},
            search: %Search{},
            pending_conflict: nil,
            keymap_scope: :editor,
            document_highlights: nil,
            agent_ui: UIState.new()

  @typedoc "A document highlight range from the LSP server."
  @type document_highlight :: Minga.LSP.DocumentHighlight.t()

  @type t :: %__MODULE__{
          vim: VimState.t(),
          buffers: Buffers.t(),
          windows: Windows.t(),
          file_tree: FileTreeState.t(),
          viewport: Viewport.t(),
          mouse: Mouse.t(),
          highlight: Highlighting.t(),
          lsp_pending: %{reference() => atom() | tuple()},
          completion: Completion.t() | nil,
          completion_trigger: CompletionTrigger.t(),
          injection_ranges: %{
            pid() => [
              %{
                start_byte: non_neg_integer(),
                end_byte: non_neg_integer(),
                language: String.t()
              }
            ]
          },
          search: Search.t(),
          pending_conflict: {pid(), String.t()} | nil,
          keymap_scope: Minga.Keymap.Scope.scope_name(),
          document_highlights: [document_highlight()] | nil,
          agent_ui: UIState.t()
        }

  @doc "Returns a list of all field names in the workspace struct."
  @spec fields() :: [atom()]
  def fields do
    %__MODULE__{viewport: Viewport.new(24, 80)}
    |> Map.keys()
    |> Kernel.--([:__struct__])
  end
end
