defmodule Minga.RenderModel.UI.StatusBar.Operation do
  @moduledoc "Inert selected-operation projection carried by the semantic status bar."

  @type kind ::
          :external_format
          | :git_stage
          | :git_unstage
          | :git_discard
          | :git_stage_all
          | :git_unstage_all
          | :git_commit
          | :lsp_references
          | :lsp_rename
  @type status ::
          :pending | :queued | :running | :success | :error | :timeout | :canceled | :stale

  @enforce_keys [:id, :kind, :status, :message, :cancelable?]
  defstruct [
    :id,
    :kind,
    :status,
    :message,
    :queue_position,
    :queue_total,
    :progress_current,
    :progress_total,
    cancelable?: false
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          kind: kind(),
          status: status(),
          message: String.t(),
          queue_position: pos_integer() | nil,
          queue_total: pos_integer() | nil,
          progress_current: non_neg_integer() | nil,
          progress_total: pos_integer() | nil,
          cancelable?: boolean()
        }
end
