defmodule MingaAgent.ModelCandidate do
  @moduledoc "Typed picker candidate for one exact executable model route."

  alias MingaAgent.ModelSelection

  @enforce_keys [:selection, :favorite, :current]
  defstruct [:selection, :favorite, :current]

  @type t :: %__MODULE__{
          selection: ModelSelection.t(),
          favorite: boolean(),
          current: boolean()
        }

  @doc "Builds a candidate and derives favorite/current flags from stable selection ids."
  @spec new(ModelSelection.t(), [String.t()], String.t() | nil) :: t()
  def new(%ModelSelection{} = selection, favorites, current_id)
      when is_list(favorites) and (is_binary(current_id) or is_nil(current_id)) do
    id = ModelSelection.id(selection)

    %__MODULE__{
      selection: selection,
      favorite: id in favorites,
      current: id == current_id
    }
  end
end
