defmodule MingaAgent.InferenceRouteRegistry.Entry do
  @moduledoc "Registered contributed route: its declaration, its models, and its last known status."

  alias MingaAgent.InferenceRoute.{Model, Spec, Status}

  @enforce_keys [:spec, :models, :status, :registration]
  defstruct [:spec, :models, :status, :registration, config: [], availability_version: 0]

  @typedoc """
  A registered route.

  `config` is the registration config, passed again to `models/1` on refresh. `registration` identifies this exact registration, so results from a check started before a re-register are discarded. `availability_version` counts availability updates, so a check that finishes after a newer report cannot overwrite it.
  """
  @type t :: %__MODULE__{
          spec: Spec.t(),
          models: [Model.t()],
          status: Status.t(),
          registration: reference(),
          config: keyword(),
          availability_version: non_neg_integer()
        }

  @doc "Builds a newly registered entry with an unknown status and a fresh registration identity."
  @spec new(Spec.t(), [Model.t()], keyword()) :: t()
  def new(%Spec{} = spec, models, config \\ []) when is_list(models) and is_list(config) do
    %__MODULE__{
      spec: spec,
      models: models,
      status: Status.unknown(),
      registration: make_ref(),
      config: config
    }
  end

  @doc "Marks a new availability update, so checks started before it are recognized as stale."
  @spec availability_updated(t()) :: t()
  def availability_updated(%__MODULE__{availability_version: version} = entry),
    do: %{entry | availability_version: version + 1}

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
