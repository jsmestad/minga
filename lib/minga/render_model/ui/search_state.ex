defmodule Minga.RenderModel.UI.SearchState do
  @moduledoc false

  @type t :: %__MODULE__{
          active: boolean(),
          match_count: non_neg_integer(),
          current_index: non_neg_integer(),
          case_sensitive: boolean(),
          whole_word: boolean(),
          regex: boolean(),
          replace_mode: boolean()
        }

  @enforce_keys [:active]
  defstruct active: false,
            match_count: 0,
            current_index: 0,
            case_sensitive: true,
            whole_word: false,
            regex: false,
            replace_mode: false
end
