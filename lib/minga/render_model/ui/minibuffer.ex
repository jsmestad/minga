defmodule Minga.RenderModel.UI.Minibuffer do
  @moduledoc """
  Semantic minibuffer model for GUI adapters.
  """

  alias Minga.RenderModel.UI.Minibuffer.Candidate

  @type mode ::
          :command
          | :search_forward
          | :search_backward
          | :search_prompt
          | :eval
          | :substitute_confirm
          | :extension_confirm
          | :describe_key
          | :delete_confirm
          | :branch_delete_confirm
          | :text_prompt
          | :unknown

  @type t :: %__MODULE__{
          visible?: boolean(),
          mode: mode(),
          cursor_pos: non_neg_integer() | nil,
          prompt: String.t(),
          input: String.t(),
          context: String.t(),
          selected_index: non_neg_integer(),
          candidates: [Candidate.t()],
          total_candidates: non_neg_integer()
        }

  defstruct visible?: false,
            mode: :command,
            cursor_pos: nil,
            prompt: "",
            input: "",
            context: "",
            selected_index: 0,
            candidates: [],
            total_candidates: 0
end
