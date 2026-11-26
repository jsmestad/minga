defmodule Minga.RenderModel.UI.Queue do
  @moduledoc "A conversation's resident queue and the controls attached to its displayed identities."

  alias Minga.RenderModel.UI.EmptyList

  @type action :: :select | :remove | :paste_after | :paste_before | :edit | :close | :composer
  @type hint :: {String.t(), String.t(), action()}
  @type row :: %{
          id: pos_integer(),
          revision: pos_integer(),
          kind: :steering | :follow_up,
          label: String.t(),
          preview: String.t(),
          attachment_count: non_neg_integer()
        }
  @type t :: %__MODULE__{
          visible?: boolean(),
          focused?: boolean(),
          workspace_id: non_neg_integer(),
          record_id: String.t(),
          title: String.t(),
          summary: String.t(),
          removed_note: String.t(),
          selected_id: pos_integer() | nil,
          hints: [hint()],
          pending: [row()],
          removed: [row()],
          empty: EmptyList.t() | nil
        }

  defstruct visible?: false,
            focused?: false,
            workspace_id: 0,
            record_id: "",
            title: "",
            summary: "",
            removed_note: "",
            selected_id: nil,
            hints: [],
            pending: [],
            removed: [],
            empty: nil
end
