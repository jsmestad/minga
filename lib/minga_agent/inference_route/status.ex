defmodule MingaAgent.InferenceRoute.Status do
  @moduledoc """
  Last known readiness and plan usage of one contributed route.

  A route starts as `:unknown` until its availability is checked or the owning extension reports it. `plan_usage` holds the limit windows the route last reported, or nil when it has reported none; Minga shows no usage without data. Availability checks and usage reports update their own field and keep the other.
  """

  alias MingaAgent.InferenceRoute
  alias MingaAgent.InferenceRoute.PlanWindow

  @enforce_keys [:availability]
  defstruct availability: :unknown, plan_usage: nil

  @type availability :: :unknown | InferenceRoute.availability()

  @type t :: %__MODULE__{availability: availability(), plan_usage: [PlanWindow.t()] | nil}

  @doc "Returns the status of a route nobody has checked yet."
  @spec unknown() :: t()
  def unknown, do: %__MODULE__{availability: :unknown}

  @doc "Builds a status from a route-reported availability, without plan usage."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_status}
  def new(%__MODULE__{availability: availability}), do: new(availability)
  def new(:unknown), do: {:ok, unknown()}

  def new({:ready, label} = availability) when is_binary(label) and label != "",
    do: {:ok, %__MODULE__{availability: availability}}

  def new({:unavailable, reason, remedy} = availability)
      when is_atom(reason) and is_binary(remedy) and remedy != "",
      do: {:ok, %__MODULE__{availability: availability}}

  def new(_availability), do: {:error, :invalid_status}

  @doc "Takes the availability of `checked` and keeps the plan usage already known."
  @spec with_availability(t(), t()) :: t()
  def with_availability(%__MODULE__{} = status, %__MODULE__{availability: availability}),
    do: %{status | availability: availability}

  @doc "Replaces the plan usage with validated windows, or nil for no data."
  @spec with_plan_usage(t(), [PlanWindow.t()] | nil) :: t()
  def with_plan_usage(%__MODULE__{} = status, windows) when is_list(windows) or is_nil(windows),
    do: %{status | plan_usage: windows}

  @doc "Returns true when the route has reported it can serve requests."
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{availability: {:ready, _label}}), do: true
  def ready?(%__MODULE__{}), do: false

  @doc "Returns the reported account label, or nil before the route reports readiness."
  @spec account_label(t()) :: String.t() | nil
  def account_label(%__MODULE__{availability: {:ready, label}}), do: label
  def account_label(%__MODULE__{}), do: nil
end
