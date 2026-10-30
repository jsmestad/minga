defmodule Minga.RenderModel.UI.FocusOwner do
  @moduledoc "The BEAM-named keyboard owner of a committed semantic frame."

  @type responder :: :editor_view | :picker_query | :search_query | :inline_edit
  @type surface ::
          :editor
          | :file_tree
          | :agent
          | :git_status
          | :conflict
          | :inline_edit
          | :inline_ask
          | :prompt
          | :picker
          | :completion
          | :command_completion
          | :search
          | :hover_popup
          | :empty_state

  @enforce_keys [:responder, :surface, :window_id]
  defstruct [:responder, :surface, :window_id, generation: 0]

  @type t :: %__MODULE__{
          responder: responder(),
          surface: surface(),
          window_id: pos_integer(),
          generation: non_neg_integer()
        }
end
