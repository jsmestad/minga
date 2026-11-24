defmodule MingaAgent.ModelCandidate do
  @moduledoc """
  Typed picker candidate for one exact executable model route.

  Contributed route candidates also carry the route's display name and last known status, so the picker can show the route's own readiness and remedy text. A contributed candidate can be unavailable; selecting it is rejected by the resolver.

  A catalog route candidate carries the subscription usage limit any session last observed on that route, while the limit is in force. It stays selectable.
  """

  alias MingaAgent.InferenceRoute.Status
  alias MingaAgent.ModelSelection
  alias MingaAgent.UsageLimit

  @enforce_keys [:selection, :favorite, :current]
  defstruct [:selection, :favorite, :current, inference_route: nil, usage_limit: nil]

  @typedoc "Display facts about the contributed route that offers this candidate."
  @type inference_route :: %{display_name: String.t(), status: Status.t()}

  @type t :: %__MODULE__{
          selection: ModelSelection.t(),
          favorite: boolean(),
          current: boolean(),
          inference_route: inference_route() | nil,
          usage_limit: UsageLimit.t() | nil
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

  @doc "Marks the candidate's route as refusing requests until the usage limit resets."
  @spec limited_by(t(), UsageLimit.t()) :: t()
  def limited_by(%__MODULE__{} = candidate, %UsageLimit{} = limit),
    do: %{candidate | usage_limit: limit}

  @doc "Returns true unless a contributed route has not reported that it is ready."
  @spec selectable_by_default?(t()) :: boolean()
  def selectable_by_default?(%__MODULE__{inference_route: nil}), do: true

  def selectable_by_default?(%__MODULE__{inference_route: %{status: status}}),
    do: Status.ready?(status)
end
