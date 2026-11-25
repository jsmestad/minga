defmodule MingaEditor.Frontend.Manager.State do
  @moduledoc """
  Internal state for the Port Manager GenServer.

  Tracks the Zig renderer port, subscribers, readiness, and terminal dimensions.
  """

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Manager.OutputPressure

  @typedoc """
  Port connection mode.

  - `:spawn`: BEAM owns the frontend as a child process in development and standalone TUI releases.
  - `:connected` — BEAM is the child; the GUI parent already set up stdin/stdout pipes. Port.Manager connects to fd 0/1 instead of spawning.
  """
  @type port_mode :: :spawn | :connected
  @type port_commander :: (port(), iodata(), [:nosuspend] -> boolean())

  @enforce_keys [:renderer_path, :output_pressure, :port_commander]
  defstruct port: nil,
            subscribers: [],
            renderer_path: "",
            port_mode: :spawn,
            ready: false,
            terminal_size: nil,
            capabilities: %Capabilities{},
            foreground: nil,
            terminal_report: nil,
            tty_path: nil,
            output_pressure: nil,
            agent_notifications: %MingaEditor.Frontend.Manager.AgentNotifications{},
            port_commander: nil,
            command_observer: nil,
            output_retry_ms: 2,
            output_failure_ms: 50,
            renderer_exit_timeout_ms: 2_000,
            renderer_env: &MingaEditor.Frontend.TerminalOverrides.launch_env/0

  @type t :: %__MODULE__{
          port: port() | nil,
          subscribers: [pid()],
          renderer_path: String.t(),
          port_mode: port_mode(),
          ready: boolean(),
          terminal_size: {width :: pos_integer(), height :: pos_integer()} | nil,
          capabilities: Capabilities.t(),
          foreground: :foreground | :background | nil,
          terminal_report: MingaEditor.Frontend.TerminalReport.t() | nil,
          tty_path: String.t() | nil,
          output_pressure: OutputPressure.t(),
          agent_notifications: MingaEditor.Frontend.Manager.AgentNotifications.t(),
          port_commander: port_commander(),
          command_observer: ([binary()] -> term()) | nil,
          output_retry_ms: pos_integer(),
          output_failure_ms: non_neg_integer(),
          renderer_exit_timeout_ms: non_neg_integer(),
          renderer_env: (-> [{charlist(), charlist()}])
        }
end
