defmodule Minga.RenderModel.UI.SearchState do
  @moduledoc false

  @type t :: %__MODULE__{
          active: boolean(),
          query: String.t(),
          session_id: non_neg_integer(),
          acknowledged_edit_seq: non_neg_integer(),
          match_count: non_neg_integer(),
          current_index: non_neg_integer(),
          case_sensitive: boolean(),
          whole_word: boolean(),
          regex: boolean(),
          replace_mode: boolean(),
          status: :ready | :loading | :rebuilding | :failed
        }

  @enforce_keys [:active]
  defstruct active: false,
            query: "",
            session_id: 0,
            acknowledged_edit_seq: 0,
            match_count: 0,
            current_index: 0,
            case_sensitive: true,
            whole_word: false,
            regex: false,
            replace_mode: false,
            status: :ready
end
