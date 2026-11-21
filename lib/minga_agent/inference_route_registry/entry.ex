defmodule MingaAgent.InferenceRouteRegistry.Entry do
  @moduledoc "Registered contributed route: its declaration, its models, and its last known status."

  alias MingaAgent.InferenceRoute.{Model, Spec, Status}

  @enforce_keys [:spec, :models, :status]
  defstruct [:spec, :models, :status, config: []]

  @typedoc "A registered route. `config` is the registration config, passed again to `models/1` on refresh."
  @type t :: %__MODULE__{
          spec: Spec.t(),
          models: [Model.t()],
          status: Status.t(),
          config: keyword()
        }

  @doc "Builds a newly registered entry with an unknown status."
  @spec new(Spec.t(), [Model.t()], keyword()) :: t()
  def new(%Spec{} = spec, models, config \\ []) when is_list(models) and is_list(config),
    do: %__MODULE__{spec: spec, models: models, status: Status.unknown(), config: config}

  @doc "Returns the entry with a refreshed, already validated model list."
  @spec with_models(t(), [Model.t()]) :: t()
  def with_models(%__MODULE__{} = entry, [_first | _rest] = models), do: %{entry | models: models}

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
