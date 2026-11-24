defmodule MingaAgent.InferenceRouteRegistry.UsageLimits do
  @moduledoc """
  The subscription usage limits sessions observed on catalog model routes, such as a ChatGPT plan's weekly limit.

  A limit applies to every model one route serves with one credential, so it is keyed by request provider and credential. `MingaAgent.InferenceRouteRegistry` holds the one shared record, so every session on a route sees the limit another session hit. A limit stays until its reset time passes or a later request on that route succeeds. Contributed routes are not recorded here: their own route reports plan windows to the registry, which owns their limit state.
  """

  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.UsageLimit

  @typep route :: {ModelSelection.Route.request_provider(), String.t()}

  @type t :: %__MODULE__{routes: %{route() => UsageLimit.t()}}

  defstruct routes: %{}

  @doc "Returns an empty record."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records that `limit` refused a request on the selection's route. A contributed route is left to its own reports."
  @spec observed(t(), ModelSelection.t() | nil, UsageLimit.t()) :: t()
  def observed(%__MODULE__{} = limits, %ModelSelection{} = selection, %UsageLimit{} = limit) do
    case route(selection) do
      {:contributed, _credential} -> limits
      route -> %{limits | routes: Map.put(limits.routes, route, limit)}
    end
  end

  def observed(%__MODULE__{} = limits, nil, %UsageLimit{}), do: limits

  @doc "Forgets the limit on the selection's route after a request on it succeeded."
  @spec request_succeeded(t(), ModelSelection.t() | nil) :: t()
  def request_succeeded(%__MODULE__{} = limits, %ModelSelection{} = selection),
    do: %{limits | routes: Map.delete(limits.routes, route(selection))}

  def request_succeeded(%__MODULE__{} = limits, nil), do: limits

  @doc "Marks each candidate whose route has a limit still in force at `now`."
  @spec annotate(t(), [ModelCandidate.t()], DateTime.t()) :: [ModelCandidate.t()]
  def annotate(%__MODULE__{routes: routes}, candidates, _now) when routes == %{}, do: candidates

  def annotate(%__MODULE__{routes: routes}, candidates, %DateTime{} = now) do
    Enum.map(candidates, fn %ModelCandidate{selection: selection} = candidate ->
      case Map.fetch(routes, route(selection)) do
        {:ok, limit} -> limit_in_force(candidate, limit, now)
        :error -> candidate
      end
    end)
  end

  @spec limit_in_force(ModelCandidate.t(), UsageLimit.t(), DateTime.t()) :: ModelCandidate.t()
  defp limit_in_force(candidate, limit, now) do
    if UsageLimit.in_force?(limit, now),
      do: ModelCandidate.limited_by(candidate, limit),
      else: candidate
  end

  @spec route(ModelSelection.t()) :: route()
  defp route(%ModelSelection{route: %{request_provider: provider}, credential: credential}),
    do: {provider, ModelSelection.credential_id(credential)}
end
