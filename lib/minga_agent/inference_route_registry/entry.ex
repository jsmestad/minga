defmodule MingaAgent.InferenceRouteRegistry.Entry do
  @moduledoc "Registered contributed route: its declaration, its models, and its last known status."

  alias MingaAgent.InferenceRoute.{Model, Spec, Status}

  @enforce_keys [:spec, :models, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{spec: Spec.t(), models: [Model.t()], status: Status.t()}

  @doc "Builds a newly registered entry with an unknown status."
  @spec new(Spec.t(), [Model.t()]) :: t()
  def new(%Spec{} = spec, models) when is_list(models),
    do: %__MODULE__{spec: spec, models: models, status: Status.unknown()}

  @doc "Returns the entry with a new status."
  @spec with_status(t(), Status.t()) :: t()
  def with_status(%__MODULE__{} = entry, %Status{} = status), do: %{entry | status: status}

  @doc "Finds one offered model by id."
  @spec model(t(), String.t()) :: {:ok, Model.t()} | {:error, :model_not_found}
  def model(%__MODULE__{models: models}, model_id) when is_binary(model_id) do
    case Enum.find(models, &(&1.id == model_id)) do
      nil -> {:error, :model_not_found}
      model -> {:ok, model}
    end
  end
end
