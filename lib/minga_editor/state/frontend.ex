defmodule MingaEditor.State.Frontend do
  @moduledoc """
  Per-editor frontend connection and capability state.

  The value owns frontend identity, rendering policy, connection handles,
  terminal dimensions, capability negotiation, pressure reporting, and input
  correlation. Renderer-owned state lives in `MingaEditor.State.Render`.

  It also keeps the picker row fit the frontend last reported. Row fit is a presentation fact the frontend owns (ADR-0001), so the editor stores the report and never derives a row count itself.
  """

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.TerminalReport
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

  @typedoc """
  Whether the frontend is in the foreground: the terminal has the window focus, or the macOS app is active.

  `:unknown` until a frontend reports it. A terminal without focus reporting never reports, so a reader must decide what `:unknown` means for its own purpose and match all three values.
  """
  @type foreground_status :: :foreground | :background | :unknown

  @type t :: %__MODULE__{
          backend: backend(),
          rendering: rendering_policy(),
          port_manager: GenServer.server() | nil,
          terminal_viewport: Viewport.t(),
          picker_rows: pos_integer() | nil,
          capabilities: Capabilities.t(),
          foreground: foreground_status(),
          terminal_report: TerminalReport.t() | nil,
          resource_pressure: ResourcePressure.t(),
          native_presentation: NativePresentationObservation.t() | nil,
          last_input_seq: non_neg_integer(),
          composer_input_offer: pos_integer() | nil,
          composer_send_now?: boolean(),
          file_dialog: file_dialog_request(),
          next_file_dialog_request_id: file_dialog_request_id()
        }

  defstruct backend: :headless,
            rendering: :enabled,
            port_manager: nil,
            terminal_viewport: Viewport.new(24, 80),
            picker_rows: nil,
            capabilities: %Capabilities{},
            foreground: :unknown,
            terminal_report: nil,
            resource_pressure: ResourcePressure.new(),
            native_presentation: nil,
            last_input_seq: 0,
            composer_input_offer: nil,
            composer_send_now?: false,
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

  @doc "Records whether the frontend reported that it is in the foreground or in the background."
  @spec report_foreground(t(), :foreground | :background) :: t()
  def report_foreground(%__MODULE__{} = frontend, status)
      when status in [:foreground, :background],
      do: %{frontend | foreground: status}

  @doc "Returns whether the frontend is in the foreground, in the background, or has not said."
  @spec foreground(t()) :: foreground_status()
  def foreground(%__MODULE__{foreground: status}), do: status

  @doc "Replaces the terminal frontend's report of its host terminal's features. Each report is a complete snapshot."
  @spec accept_terminal_report(t(), TerminalReport.t()) :: t()
  def accept_terminal_report(%__MODULE__{} = frontend, %TerminalReport{} = report),
    do: %{frontend | terminal_report: report}

  @doc "Returns the terminal frontend's report, or `nil` when the frontend has no host terminal or has not reported yet."
  @spec terminal_report(t()) :: TerminalReport.t() | nil
  def terminal_report(%__MODULE__{terminal_report: report}), do: report

  @doc "Forgets what a frontend connection reported about itself: a new connection reports again."
  @spec clear_connection_reports(t()) :: t()
  def clear_connection_reports(%__MODULE__{} = frontend),
    do: %{frontend | foreground: :unknown, terminal_report: nil}

  @doc "Clears connection-scoped native presentation evidence."
  @spec clear_native_presentation(t()) :: t()
  def clear_native_presentation(%__MODULE__{} = frontend),
    do: %{frontend | native_presentation: nil}

  @doc "Records the terminal viewport reported by the active frontend."
  @spec resize_terminal(t(), Viewport.t()) :: t()
  def resize_terminal(%__MODULE__{} = frontend, %Viewport{} = viewport),
    do: %{frontend | terminal_viewport: viewport}

  @doc """
  Records how many result rows the frontend's picker list shows.

  The report outlives the picker that produced it, so a key typed before the next picker is drawn pages by the rows the frontend last showed.
  """
  @spec report_picker_rows(t(), pos_integer()) :: t()
  def report_picker_rows(%__MODULE__{} = frontend, rows) when is_integer(rows) and rows > 0,
    do: %{frontend | picker_rows: rows}

  @doc "Forgets the picker row report when another frontend attaches."
  @spec clear_picker_rows(t()) :: t()
  def clear_picker_rows(%__MODULE__{} = frontend), do: %{frontend | picker_rows: nil}

  @doc """
  Returns how many rows one picker page moves.

  A frontend that has reported its picker rows pages by that count. Until a report arrives, a page is one row: the editor cannot know what the frontend shows, and a page must never pass a row the user has not seen.
  """
  @spec picker_page_rows(t()) :: pos_integer()
  def picker_page_rows(%__MODULE__{picker_rows: nil}), do: 1
  def picker_page_rows(%__MODULE__{picker_rows: rows}), do: rows

  @doc "Scopes a committed composer offer to one dispatched input."
  @spec composer_input(t(), pos_integer() | nil, boolean()) :: t()
  def composer_input(%__MODULE__{} = frontend, offer, send_now? \\ false),
    do: %{frontend | composer_input_offer: offer, composer_send_now?: send_now?}

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
