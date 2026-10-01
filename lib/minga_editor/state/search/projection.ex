defmodule MingaEditor.State.Search.Projection do
  @moduledoc false

  @type status :: :ready | :loading | :rebuilding | :failed

  @enforce_keys [
    :active,
    :query,
    :session_id,
    :acknowledged_edit_seq,
    :match_count,
    :current_index,
    :case_sensitive,
    :whole_word,
    :regex,
    :replace_mode,
    :status,
    :generation,
    :query_revision
  ]
  defstruct @enforce_keys

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
          status: status(),
          generation: Minga.Search.IndexGeneration.t() | nil,
          query_revision: non_neg_integer()
        }
end
