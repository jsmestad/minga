defmodule MingaEditor.State.Frontend do
  @moduledoc """
  Per-editor frontend connection and capability state.

  The value owns frontend identity, rendering policy, connection handles,
  terminal dimensions, capability negotiation, pressure reporting, and input
  correlation. Renderer-owned state lives in `MingaEditor.State.Render`.
  """

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.NativeIPC.NativePresentationObservation
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.Viewport

  @type backend :: :tui | :gui | :native_gui | :headless
  @type rendering_policy :: :enabled | :disabled
  @type file_dialog_request_id :: 0..0xFFFFFFFF
  @type file_dialog_request ::
          :idle
          | {:open, file_dialog_request_id()}
          | {:save_as, file_dialog_request_id(), pid()}

  @type t :: %__MODULE__{
          backend: backend(),
          rendering: rendering_policy(),
          port_manager: GenServer.server() | nil,
          terminal_viewport: Viewport.t(),
          capabilities: Capabilities.t(),
          resource_pressure: ResourcePressure.t(),
          native_presentation: NativePresentationObservation.t() | nil,
          last_input_seq: non_neg_integer(),
          file_dialog: file_dialog_request(),
          next_file_dialog_request_id: file_dialog_request_id()
        }

  defstruct backend: :headless,
            rendering: :enabled,
            port_manager: nil,
            terminal_viewport: Viewport.new(24, 80),
            capabilities: %Capabilities{},
            resource_pressure: ResourcePressure.new(),
            native_presentation: nil,
            last_input_seq: 0,
            file_dialog: :idle,
            next_file_dialog_request_id: 1

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

  @doc "Clears connection-scoped native presentation evidence."
  @spec clear_native_presentation(t()) :: t()
  def clear_native_presentation(%__MODULE__{} = frontend),
    do: %{frontend | native_presentation: nil}

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

  @doc "Records the latest native presentation proven by the connected frontend."
  @spec observe_native_presentation(t(), NativePresentationObservation.t()) :: t()
  def observe_native_presentation(
        %__MODULE__{} = frontend,
        %NativePresentationObservation{} = observation
      ),
      do: %{frontend | native_presentation: observation}

  @doc "Begins one native file-dialog request and retains its BEAM-owned origin."
  @spec begin_file_dialog(t(), :open | {:save_as, pid()}) ::
          {:ok, file_dialog_request_id(), t()} | {:error, :busy}
  def begin_file_dialog(%__MODULE__{file_dialog: :idle} = frontend, :open) do
    request_id = frontend.next_file_dialog_request_id

    {:ok, request_id,
     %{
       frontend
       | file_dialog: {:open, request_id},
         next_file_dialog_request_id: next_request_id(request_id)
     }}
  end

  def begin_file_dialog(%__MODULE__{file_dialog: :idle} = frontend, {:save_as, buffer})
      when is_pid(buffer) do
    request_id = frontend.next_file_dialog_request_id

    {:ok, request_id,
     %{
       frontend
       | file_dialog: {:save_as, request_id, buffer},
         next_file_dialog_request_id: next_request_id(request_id)
     }}
  end

  def begin_file_dialog(%__MODULE__{}, _request), do: {:error, :busy}

  @doc "Takes the matching file-dialog origin and rejects stale or mismatched results."
  @spec take_file_dialog(t(), file_dialog_request_id()) ::
          {:ok, file_dialog_request(), t()} | :stale
  def take_file_dialog(
        %__MODULE__{file_dialog: {:open, request_id}} = frontend,
        request_id
      ),
      do: {:ok, frontend.file_dialog, %{frontend | file_dialog: :idle}}

  def take_file_dialog(
        %__MODULE__{file_dialog: {:save_as, request_id, _buffer}} = frontend,
        request_id
      ),
      do: {:ok, frontend.file_dialog, %{frontend | file_dialog: :idle}}

  def take_file_dialog(%__MODULE__{}, _request_id), do: :stale

  @doc "Clears a request whose frontend command was not admitted."
  @spec cancel_file_dialog(t(), file_dialog_request_id()) :: t()
  def cancel_file_dialog(%__MODULE__{} = frontend, request_id) do
    case take_file_dialog(frontend, request_id) do
      {:ok, _request, next} -> next
      :stale -> frontend
    end
  end

  @doc "Drops connection-scoped file-dialog ownership without reusing its request id."
  @spec clear_file_dialog(t()) :: t()
  def clear_file_dialog(%__MODULE__{} = frontend), do: %{frontend | file_dialog: :idle}

  @doc "Correlates the next committed frame with the latest frontend input."
  @spec correlate_input(t(), non_neg_integer()) :: t()
  def correlate_input(%__MODULE__{} = frontend, sequence)
      when is_integer(sequence) and sequence >= 0,
      do: %{frontend | last_input_seq: sequence}

  @spec next_request_id(file_dialog_request_id()) :: file_dialog_request_id()
  defp next_request_id(0xFFFFFFFF), do: 1
  defp next_request_id(request_id), do: request_id + 1
end
