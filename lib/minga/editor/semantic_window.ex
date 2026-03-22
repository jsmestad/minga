defmodule Minga.Editor.SemanticWindow do
  @moduledoc """
  Pre-resolved semantic rendering data for one editor window.

  This struct captures everything a GUI frontend needs to render a buffer
  window without interpreting TUI cell-grid commands. The BEAM resolves
  all layout (word wrap, folding, virtual text splicing, conceal ranges)
  and all styling (syntax highlighting, selection, search matches) before
  populating this struct.

  The struct is built alongside the existing `WindowFrame` draws in the
  Content stage. In Phase 2 of the gui_window_content work (#828), the
  Emit stage will encode this struct as opcode 0x80 for GUI frontends.

  ## Design Principles

  1. **BEAM is the single source of truth.** Swift never computes word wrap,
     fold resolution, or display column offsets. Everything is pre-resolved.

  2. **Display coordinates everywhere.** All positions (cursor, selection,
     search matches, diagnostics) use display row/column, not buffer
     line/byte-col. This means virtual text displacement, fold collapsing,
     and wrap breaks are already accounted for.

  3. **Composed text.** Each visual row carries the final UTF-8 text that
     should be rendered, with inline virtual text already spliced and
     conceal ranges already applied.

  4. **Overlay data separate from spans.** Selection and search matches are
     sent as coordinate ranges, not baked into span colors. This lets the
     GUI render them as Metal quads (zero re-rasterization on selection
     change).
  """

  alias __MODULE__.{
    DiagnosticRange,
    DocumentHighlightRange,
    ResolvedAnnotation,
    SearchMatch,
    Selection,
    VisualRow
  }

  @enforce_keys [:window_id, :rows, :cursor_row, :cursor_col, :cursor_shape]
  defstruct window_id: 0,
            rows: [],
            cursor_row: 0,
            cursor_col: 0,
            cursor_shape: :block,
            cursor_visible: true,
            scroll_left: 0,
            selection: nil,
            search_matches: [],
            diagnostic_ranges: [],
            document_highlights: [],
            annotations: [],
            full_refresh: true

  @type cursor_shape :: :block | :beam | :underline

  @type t :: %__MODULE__{
          window_id: pos_integer(),
          rows: [VisualRow.t()],
          cursor_row: non_neg_integer(),
          cursor_col: non_neg_integer(),
          cursor_shape: cursor_shape(),
          cursor_visible: boolean(),
          scroll_left: non_neg_integer(),
          selection: Selection.t() | nil,
          search_matches: [SearchMatch.t()],
          diagnostic_ranges: [DiagnosticRange.t()],
          document_highlights: [DocumentHighlightRange.t()],
          annotations: [ResolvedAnnotation.t()],
          full_refresh: boolean()
        }
end
