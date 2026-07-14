defmodule MingaEditor.Effects.TodoSearch.Result do
  @moduledoc "Completed TODO-search candidates and their picker correlation data."

  alias MingaEditor.UI.Picker.Candidate

  @enforce_keys [:revision, :items, :candidates, :meta]
  defstruct [:revision, :items, :candidates, :meta]

  @type t :: %__MODULE__{
          revision: reference(),
          items: [MingaEditor.UI.Picker.Item.t()],
          candidates: [Candidate.t()],
          meta: MingaEditor.UI.Picker.Source.fetch_meta()
        }
end
