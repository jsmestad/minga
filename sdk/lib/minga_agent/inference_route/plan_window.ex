defmodule MingaAgent.InferenceRoute.PlanWindow do
  @moduledoc """
  One subscription limit window a route reports through `Minga.Extension.ModelRoutes.report_usage/3`.

  `utilization` is the used fraction from 0 to 1, `resets_at` is a `DateTime` or nil, and `status` is `:allowed`, `:warning`, or `:rejected`.

  This is a compile-time stub.
  """

  @enforce_keys [:kind, :utilization, :resets_at, :status]
  defstruct @enforce_keys

  @type status :: :allowed | :warning | :rejected

  @type t :: %__MODULE__{
          kind: String.t(),
          utilization: float(),
          resets_at: DateTime.t() | nil,
          status: status()
        }

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, {:invalid_plan_window, atom()}}
  def new(_attrs), do: raise("minga_sdk is compile-time only")
end
