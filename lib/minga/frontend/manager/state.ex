defmodule Minga.Frontend.Manager.State do
  @moduledoc """
  Internal state for the Port Manager GenServer.

  Tracks the Zig renderer port, subscribers, readiness, and terminal dimensions.
  """

  alias Minga.Frontend.Capabilities

  @typedoc """
  Port connection mode.

  - `:spawn` — BEAM is the parent; Port.Manager spawns the GUI as a child process (dev mode, TUI, Burrito).
  - `:connected` — BEAM is the child; the GUI parent already set up stdin/stdout pipes. Port.Manager connects to fd 0/1 instead of spawning.
  """
  @type port_mode :: :spawn | :connected

  @enforce_keys [:renderer_path]
  defstruct port: nil,
            subscribers: [],
            renderer_path: "",
            port_mode: :spawn,
            ready: false,
            terminal_size: nil,
            capabilities: %Capabilities{}

  @type t :: %__MODULE__{
          port: port() | nil,
          subscribers: [pid()],
          renderer_path: String.t(),
          port_mode: port_mode(),
          ready: boolean(),
          terminal_size: {width :: pos_integer(), height :: pos_integer()} | nil,
          capabilities: Capabilities.t()
        }
end
