defmodule MingaEditor.State.Frontend do
  @moduledoc """
  Per-editor frontend connection and capability state.

  The value owns frontend identity, rendering policy, connection handles,
  terminal dimensions, capability negotiation, pressure reporting, and input
  correlation. Renderer-owned state lives in `MingaEditor.State.Render`.
  """

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.Viewport

  @type backend :: :tui | :gui | :native_gui | :headless
  @type rendering_policy :: :enabled | :disabled

  @type t :: %__MODULE__{
          backend: backend(),
          rendering: rendering_policy(),
          port_manager: GenServer.server() | nil,
          terminal_viewport: Viewport.t(),
          capabilities: Capabilities.t(),
          resource_pressure: ResourcePressure.t(),
          last_input_seq: non_neg_integer()
        }

  defstruct backend: :headless,
            rendering: :enabled,
            port_manager: nil,
            terminal_viewport: Viewport.new(24, 80),
            capabilities: %Capabilities{},
            resource_pressure: ResourcePressure.new(),
            last_input_seq: 0

  @doc "Builds frontend state from editor startup options."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      backend: Keyword.get(opts, :backend, :headless),
      rendering: Keyword.get(opts, :rendering, :enabled),
      port_manager: Keyword.get(opts, :port_manager),
      terminal_viewport: Keyword.get(opts, :terminal_viewport, Viewport.new(24, 80)),
      capabilities: Keyword.get(opts, :capabilities, %Capabilities{})
    }
  end

  @doc "Returns whether this editor emits rendered frames."
  @spec rendering_enabled?(t()) :: boolean()
  def rendering_enabled?(%__MODULE__{rendering: :enabled}), do: true
  def rendering_enabled?(%__MODULE__{rendering: :disabled}), do: false

  @doc "Accepts frontend capability negotiation."
  @spec accept_capabilities(t(), Capabilities.t()) :: t()
  def accept_capabilities(%__MODULE__{} = frontend, %Capabilities{} = capabilities),
    do: %{frontend | capabilities: capabilities}

  @doc "Records the terminal viewport reported by the active frontend."
  @spec resize_terminal(t(), Viewport.t()) :: t()
  def resize_terminal(%__MODULE__{} = frontend, %Viewport{} = viewport),
    do: %{frontend | terminal_viewport: viewport}

  @doc "Records the frontend's current resource-pressure report."
  @spec report_resource_pressure(t(), boolean(), ResourcePressure.thermal_state()) :: t()
  def report_resource_pressure(%__MODULE__{} = frontend, low_power?, thermal_state)
      when is_boolean(low_power?) do
    pressure = ResourcePressure.update(frontend.resource_pressure, low_power?, thermal_state)
    %{frontend | resource_pressure: pressure}
  end

  @doc "Correlates the next committed frame with the latest frontend input."
  @spec correlate_input(t(), non_neg_integer()) :: t()
  def correlate_input(%__MODULE__{} = frontend, sequence)
      when is_integer(sequence) and sequence >= 0,
      do: %{frontend | last_input_seq: sequence}
end
