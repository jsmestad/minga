defmodule MingaAgent.ModelCandidate do
  @moduledoc """
  Typed picker candidate for one exact executable model route.

  Contributed route candidates also carry the route's display name and last known status, so the picker can show the route's own readiness and remedy text. A contributed candidate can be unavailable; selecting it is rejected by the resolver.
  """

  alias MingaAgent.InferenceRoute.Status
  alias MingaAgent.ModelSelection

  @enforce_keys [:selection, :favorite, :current]
  defstruct [:selection, :favorite, :current, inference_route: nil]

  @typedoc "Display facts about the contributed route that offers this candidate."
  @type inference_route :: %{display_name: String.t(), status: Status.t()}

  @type t :: %__MODULE__{
          selection: ModelSelection.t(),
          favorite: boolean(),
          current: boolean(),
          inference_route: inference_route() | nil
        }

  @doc "Builds a candidate and derives favorite/current flags from stable selection ids."
  @spec new(ModelSelection.t(), [String.t()], String.t() | nil, inference_route() | nil) :: t()
  def new(%ModelSelection{} = selection, favorites, current_id, inference_route \\ nil)
      when is_list(favorites) and (is_binary(current_id) or is_nil(current_id)) do
    id = ModelSelection.id(selection)

    %__MODULE__{
      selection: selection,
      favorite: id in favorites,
      current: id == current_id,
      inference_route: inference_route
    }
  end

  @doc "Returns true unless a contributed route has not reported that it is ready."
  @spec selectable_by_default?(t()) :: boolean()
  def selectable_by_default?(%__MODULE__{inference_route: nil}), do: true

  def selectable_by_default?(%__MODULE__{inference_route: %{status: status}}),
    do: Status.ready?(status)
end
