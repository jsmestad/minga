defmodule MingaAgent.InferenceRoute.Status do
  @moduledoc """
  Last known readiness of one contributed route.

  A route starts as `:unknown` until its availability is checked or the owning extension reports it. `plan_usage` is reserved for subscription usage display and is always nil for now.
  """

  alias MingaAgent.InferenceRoute

  @enforce_keys [:availability]
  defstruct availability: :unknown, plan_usage: nil

  @type availability :: :unknown | InferenceRoute.availability()

  @type t :: %__MODULE__{availability: availability(), plan_usage: nil}

  @doc "Returns the status of a route nobody has checked yet."
  @spec unknown() :: t()
  def unknown, do: %__MODULE__{availability: :unknown}

  @doc "Builds a status from a route-reported availability."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_status}
  def new(%__MODULE__{availability: availability, plan_usage: nil}), do: new(availability)
  def new(:unknown), do: {:ok, unknown()}

  def new({:ready, label} = availability) when is_binary(label) and label != "",
    do: {:ok, %__MODULE__{availability: availability}}

  def new({:unavailable, reason, remedy} = availability)
      when is_atom(reason) and is_binary(remedy) and remedy != "",
      do: {:ok, %__MODULE__{availability: availability}}

  def new(_availability), do: {:error, :invalid_status}

  @doc "Returns true when the route has reported it can serve requests."
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{availability: {:ready, _label}}), do: true
  def ready?(%__MODULE__{}), do: false

  @doc "Returns the reported account label, or nil before the route reports readiness."
  @spec account_label(t()) :: String.t() | nil
  def account_label(%__MODULE__{availability: {:ready, label}}), do: label
  def account_label(%__MODULE__{}), do: nil
end
