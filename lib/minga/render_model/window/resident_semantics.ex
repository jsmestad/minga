defmodule Minga.RenderModel.Window.ResidentSemantics do
  @moduledoc """
  Atomic resident semantic state published beside a retained text row store.

  Coordinates are absolute resident row ranks. A keyframe replaces every layer; a delta replaces only the explicitly named sparse layers and applies bounded guide range replacements after the row-rank splices.
  """

  alias Minga.RenderModel.Window.{Annotation, DiagnosticRange}

  defmodule Header do
    @moduledoc "Identity, revision, and resident extent for one atomic semantic publication."
    @enforce_keys [
      :window_id,
      :content_epoch,
      :mode,
      :base_revision,
      :revision,
      :target_row_revision,
      :row_count,
      :first_row_id,
      :last_row_id
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            window_id: pos_integer(),
            content_epoch: non_neg_integer(),
            mode: :keyframe | :delta,
            base_revision: non_neg_integer(),
            revision: pos_integer(),
            target_row_revision: pos_integer(),
            row_count: non_neg_integer(),
            first_row_id: non_neg_integer(),
            last_row_id: non_neg_integer()
          }
  end

  defmodule Cursor do
    @moduledoc "Resident cursor eligibility and absolute position."
    @enforce_keys [:eligible, :row, :col]
    defstruct [:eligible, :row, :col]

    @type t :: %__MODULE__{eligible: boolean(), row: non_neg_integer(), col: non_neg_integer()}
  end

  defmodule Cursorline do
    @moduledoc "Resident cursorline target in absolute row coordinates."
    @enforce_keys [:row, :bg_rgb]
    defstruct [:row, :bg_rgb]

    @type t :: %__MODULE__{row: non_neg_integer(), bg_rgb: non_neg_integer()}
  end

  defmodule Selection do
    @moduledoc "Resident selection endpoints in absolute row coordinates."
    @enforce_keys [:type, :start_row, :start_col, :end_row, :end_col]
    defstruct [:type, :start_row, :start_col, :end_row, :end_col]

    @type t :: %__MODULE__{
            type: :char | :line,
            start_row: non_neg_integer(),
            start_col: non_neg_integer(),
            end_row: non_neg_integer(),
            end_col: non_neg_integer()
          }
  end

  defmodule GuideRun do
    @moduledoc "Half-open absolute row range with one resolved indent level."
    @enforce_keys [:start_row, :end_row, :level]
    defstruct [:start_row, :end_row, :level]

    @type t :: %__MODULE__{
            start_row: non_neg_integer(),
            end_row: non_neg_integer(),
            level: non_neg_integer()
          }
  end

  defmodule GuideReplace do
    @moduledoc "Replacement for one half-open resident guide range."
    @enforce_keys [:start_row, :end_row, :runs]
    defstruct [:start_row, :end_row, :runs]

    @type t :: %__MODULE__{
            start_row: non_neg_integer(),
            end_row: non_neg_integer(),
            runs: [GuideRun.t()]
          }
  end

  defmodule RowSplice do
    @moduledoc "Row-rank transform applied to retained semantic ranges."
    @enforce_keys [:start_row, :delete_count, :insert_count]
    defstruct [:start_row, :delete_count, :insert_count]

    @type t :: %__MODULE__{
            start_row: non_neg_integer(),
            delete_count: non_neg_integer(),
            insert_count: non_neg_integer()
          }
  end

  defmodule AnnotationReplace do
    @moduledoc "Replacement for annotations in one half-open absolute row range."
    @enforce_keys [:start_row, :end_row, :annotations]
    defstruct [:start_row, :end_row, :annotations]

    @type t :: %__MODULE__{
            start_row: non_neg_integer(),
            end_row: non_neg_integer(),
            annotations: [Annotation.t()]
          }
  end

  defmodule DiagnosticReplace do
    @moduledoc "Replacement for diagnostics grouped by start rank in one half-open range."
    @enforce_keys [:start_row, :end_row, :diagnostics]
    defstruct [:start_row, :end_row, :diagnostics]

    @type t :: %__MODULE__{
            start_row: non_neg_integer(),
            end_row: non_neg_integer(),
            diagnostics: [DiagnosticRange.t()]
          }
  end

  @enforce_keys [
    :header,
    :cursor,
    :tab_width,
    :active_guide_col,
    :guide_cols,
    :row_splices,
    :guide_replacements
  ]
  defstruct @enforce_keys ++
              [
                cursorline: nil,
                selection: nil,
                diagnostics: :retain,
                annotations: :retain
              ]

  @type t :: %__MODULE__{
          header: Header.t(),
          cursor: Cursor.t(),
          cursorline: Cursorline.t() | nil,
          selection: Selection.t() | nil,
          diagnostics:
            :retain
            | {:replace, [DiagnosticRange.t()]}
            | {:replace_ranges, [DiagnosticReplace.t()]},
          annotations:
            :retain | {:replace, [Annotation.t()]} | {:replace_ranges, [AnnotationReplace.t()]},
          tab_width: pos_integer(),
          active_guide_col: non_neg_integer(),
          guide_cols: [non_neg_integer()],
          row_splices: [RowSplice.t()],
          guide_replacements: [GuideReplace.t()]
        }
end
