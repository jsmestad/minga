defmodule Minga.Surface.BufferView.State do
  @moduledoc """
  Internal state for the BufferView surface.

  Groups all buffer-editing concerns that were previously spread across
  `EditorState`. The struct is organized into two layers:

  1. **View state** — buffer list, window tree, file tree, viewport,
     highlighting, LSP sync, completion, git, and other per-view data.
  2. **Editing model state** — vim-specific modal state (mode FSM, marks,
     registers, find-char, change recorder, macro recorder). Lives in
     the `editing` sub-struct so future editing models (CUA, #306) can
     swap in their own state without touching the view layer.

  ## Relationship to EditorState

  During Phase 1 of the Surface extraction, a bridge layer copies fields
  between `EditorState` and this struct before/after each surface call.
  This dual-ownership is temporary scaffolding that goes away when
  `EditorState` shrinks in Phase 2.
  """

  alias Minga.Completion
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.State.Mouse
  alias Minga.Editor.State.Registers
  alias Minga.Editor.State.Search
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Mode

  # ── Editing model (vim) ────────────────────────────────────────────────────

  defmodule VimState do
    @moduledoc """
    Vim-specific editing model state.

    Contains the modal FSM state, registers, marks, and recording state
    that are specific to vim-style editing. This is the default editing
    model; future models (CUA, #306) would define their own state struct.
    """

    alias Minga.Buffer.Document
    alias Minga.Editor.ChangeRecorder
    alias Minga.Editor.MacroRecorder
    alias Minga.Editor.State.Registers
    alias Minga.Mode

    @typedoc "Stored last find-char motion for ; and , repeat."
    @type last_find_char :: {Minga.Mode.State.find_direction(), String.t()} | nil

    @typedoc "Buffer-local marks: outer key is buffer pid, inner key is mark name."
    @type marks :: %{pid() => %{String.t() => Document.position()}}

    @type t :: %__MODULE__{
            mode: Mode.mode(),
            mode_state: Mode.state(),
            reg: Registers.t(),
            marks: marks(),
            last_jump_pos: Document.position() | nil,
            last_find_char: last_find_char(),
            change_recorder: ChangeRecorder.t(),
            macro_recorder: MacroRecorder.t()
          }

    @enforce_keys [:mode, :mode_state]
    defstruct mode: :normal,
              mode_state: nil,
              reg: %Registers{},
              marks: %{},
              last_jump_pos: nil,
              last_find_char: nil,
              change_recorder: ChangeRecorder.new(),
              macro_recorder: MacroRecorder.new()
  end

  # ── BufferView state ───────────────────────────────────────────────────────

  @typedoc "The editing model sub-state. Currently always VimState."
  @type editing_state :: VimState.t()

  @type t :: %__MODULE__{
          buffers: Buffers.t(),
          windows: Windows.t(),
          file_tree: FileTreeState.t(),
          viewport: Viewport.t(),
          mouse: Mouse.t(),
          highlight: Highlighting.t(),
          lsp: DocumentSync.t(),
          completion: Completion.t() | nil,
          completion_trigger: CompletionTrigger.t(),
          git_buffers: %{pid() => pid()},
          injection_ranges: %{
            pid() => [
              %{start_byte: non_neg_integer(), end_byte: non_neg_integer(), language: String.t()}
            ]
          },
          search: Search.t(),
          pending_conflict: {pid(), String.t()} | nil,
          editing: editing_state()
        }

  @enforce_keys [:viewport, :editing]
  defstruct buffers: %Buffers{},
            windows: %Windows{},
            file_tree: %FileTreeState{},
            viewport: nil,
            mouse: %Mouse{},
            highlight: %Highlighting{},
            lsp: DocumentSync.new(),
            completion: nil,
            completion_trigger: CompletionTrigger.new(),
            git_buffers: %{},
            injection_ranges: %{},
            search: %Search{},
            pending_conflict: nil,
            editing: nil
end
