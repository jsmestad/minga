defmodule MingaEditor.State.ResourcePressure do
  @moduledoc """
  Tracks frontend-reported macOS low power mode and thermal pressure.

  The BEAM owns render pacing, so this state converts resource-pressure signals from native frontends into a minimum render debounce. Normal operation remains at the caller-requested cadence.
  """

  @enforce_keys [:low_power?, :thermal_state]
  defstruct low_power?: false, thermal_state: :nominal

  @typedoc "Thermal pressure level reported by the native GUI frontend."
  @type thermal_state :: :nominal | :fair | :serious | :critical | {:unknown, non_neg_integer()}

  @type t :: %__MODULE__{low_power?: boolean(), thermal_state: thermal_state()}

  @doc "Returns the default no-pressure state."
  @spec new() :: t()
  def new, do: %__MODULE__{low_power?: false, thermal_state: :nominal}

  @doc "Updates the current resource-pressure state."
  @spec update(t(), boolean(), thermal_state()) :: t()
  def update(%__MODULE__{} = state, low_power?, thermal_state) when is_boolean(low_power?) do
    %{state | low_power?: low_power?, thermal_state: thermal_state}
  end

  @doc "Returns the minimum render debounce in milliseconds for the current pressure level."
  @spec render_delay_ms(t()) :: non_neg_integer()
  def render_delay_ms(%__MODULE__{thermal_state: :critical}), do: 100
  def render_delay_ms(%__MODULE__{thermal_state: :serious}), do: 33
  def render_delay_ms(%__MODULE__{thermal_state: :fair}), do: 22
  def render_delay_ms(%__MODULE__{low_power?: true}), do: 33
  def render_delay_ms(%__MODULE__{}), do: 0
end
