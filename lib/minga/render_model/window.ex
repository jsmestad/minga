defmodule Minga.RenderModel.Window do
  @moduledoc """
  Canonical visible model for one buffer-like window.

  The Content stage builds this model from current-frame data. Frontend adapters encode it for GUI or composite it into cells for TUI proof-of-concept paths. The struct is pure data and lives in core so products can produce window content without importing `MingaEditor`.

  `contiguous_rows` is a BEAM-internal hint (never encoded on the wire): it is true only for the non-wrapped, non-folded sequential path, where `rows` are consecutive `:normal` buffer lines. It lets `ScrollPresentation` derive the resident line range by arithmetic instead of folding over every row.

  `content_digest` is a BEAM-internal, never-encoded incremental fingerprint of the row set (`Minga.RenderModel.Window.ContentDigest`), set only on the full-document residence path. When present, the GUI adapter's content frame-emit gate uses it instead of hashing the whole `rows` list, so an edit-frame gate is O(changed rows) rather than O(document). It is `nil` off the residence path, where the adapter keeps hashing `rows` directly.

  `scroll_seq` is the monotonic scroll-authority sequence (#2661) encoded onto `ScrollPresentation`. It advances when the committed viewport top changes for a reason other than an echoed frontend scroll report, or when an authoritative viewport-jump command explicitly marked the window even though the top was unchanged (#2652); see `MingaEditor.Window.settle_scroll_seq/1`. Frontends discard their local offset on any increase, so a BEAM-initiated jump racing a local scroll is distinguished from the frontend's own reported delta being reflected back.
  """

  alias __MODULE__.{
    Annotation,
    Cursorline,
    DiagnosticRange,
    DocumentHighlight,
    Gutter,
    IndentGuides,
    PaneGeometry,
    Row,
    SearchMatch,
    Selection
  }

  @type content_kind :: :buffer | :agent_chat | :agent_prompt
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
            geometry: nil,
            content_epoch: 0,
            full_refresh: true,
            contiguous_rows: false,
            content_digest: nil,
            scroll_seq: 0

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
          geometry: PaneGeometry.t() | nil,
          content_epoch: non_neg_integer(),
          full_refresh: boolean(),
          contiguous_rows: boolean(),
          content_digest: Minga.RenderModel.Window.ContentDigest.t() | nil,
          scroll_seq: non_neg_integer()
        }
end
