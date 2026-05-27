defmodule Minga.RenderModel.Window do
  @moduledoc """
  Canonical visible model for one buffer-like window.

  The Content stage builds this model from current-frame data. Frontend adapters encode it for GUI or composite it into cells for TUI proof-of-concept paths. The struct is pure data and lives in core so products can produce window content without importing `MingaEditor`.
  """

  alias __MODULE__.{
    Annotation,
    Cursorline,
    DiagnosticRange,
    DocumentHighlight,
    Gutter,
    IndentGuides,
    Row,
    SearchMatch,
    Selection
  }

  @type content_kind :: :buffer | :agent_chat | :agent_prompt | :dashboard
  @type cursor_shape :: :block | :beam | :underline
  @type rect ::
          {row :: non_neg_integer(), col :: non_neg_integer(), width :: non_neg_integer(),
           height :: non_neg_integer()}

  @enforce_keys [:window_id, :content_kind, :rect, :rows, :cursor_row, :cursor_col, :cursor_shape]
  defstruct window_id: 0,
            content_kind: :buffer,
            rect: {0, 0, 0, 0},
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
            gutter: nil,
            cursorline: nil,
            indent_guides: nil,
            full_refresh: true

  @type t :: %__MODULE__{
          window_id: pos_integer(),
          content_kind: content_kind(),
          rect: rect(),
          rows: [Row.t()],
          cursor_row: non_neg_integer(),
          cursor_col: non_neg_integer(),
          cursor_shape: cursor_shape(),
          cursor_visible: boolean(),
          scroll_left: non_neg_integer(),
          selection: Selection.t() | nil,
          search_matches: [SearchMatch.t()],
          diagnostic_ranges: [DiagnosticRange.t()],
          document_highlights: [DocumentHighlight.t()],
          annotations: [Annotation.t()],
          gutter: Gutter.t() | nil,
          cursorline: Cursorline.t() | nil,
          indent_guides: IndentGuides.t() | nil,
          full_refresh: boolean()
        }
end
