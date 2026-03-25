defmodule Minga.Workspace.State do
  @moduledoc """
  Core editing context that exists regardless of presentation.

  A workspace is the editing state that gets saved/restored when
  switching tabs. It works identically whether rendered as a tab in
  the traditional editor, a card on The Board, or running headless
  without any UI.

  This struct formalizes the `@per_tab_fields` boundary from
  `Minga.Editor.State`: every field here is snapshotted per tab and
  restored on tab switch.
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
  alias Minga.Keymap.Scope

  @typedoc "A document highlight range from the LSP server."
  @type document_highlight :: Minga.LSP.DocumentHighlight.t()

  @type t :: %__MODULE__{
          keymap_scope: Scope.scope_name(),
          buffers: Buffers.t(),
          windows: Windows.t(),
          file_tree: FileTreeState.t(),
          viewport: Viewport.t(),
          mouse: Mouse.t(),
          highlight: Highlighting.t(),
          lsp_pending: %{reference() => atom() | tuple()},
          completion: Completion.t() | nil,
          completion_trigger: CompletionTrigger.t(),
          injection_ranges: %{pid() => [Minga.Highlight.InjectionRange.t()]},
          search: Search.t(),
          pending_conflict: {pid(), String.t()} | nil,
          vim: VimState.t(),
          document_highlights: [document_highlight()] | nil,
          agent_ui: UIState.t()
        }

  @enforce_keys [:viewport]
  defstruct keymap_scope: :editor,
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
            vim: VimState.new(),
            document_highlights: nil,
            agent_ui: UIState.new()

  @doc "Returns the list of field names (for snapshot/restore compatibility)."
  @spec field_names() :: [atom()]
  def field_names do
    %__MODULE__{viewport: %Viewport{top: 0, left: 0, rows: 1, cols: 1}}
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
  end
end
