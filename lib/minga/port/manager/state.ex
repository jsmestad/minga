defmodule Minga.Port.Manager.State do
  @moduledoc """
  Internal state for the Port Manager GenServer.

  Tracks the Zig renderer port, subscribers, readiness, and terminal dimensions.
  """

  alias Minga.Port.Capabilities

  @enforce_keys [:renderer_path]
  defstruct port: nil,
            subscribers: [],
            renderer_path: "",
            ready: false,
            terminal_size: nil,
            capabilities: %Capabilities{}

  @type t :: %__MODULE__{
          port: port() | nil,
          subscribers: [pid()],
          renderer_path: String.t(),
          ready: boolean(),
          terminal_size: {width :: pos_integer(), height :: pos_integer()} | nil,
          capabilities: Capabilities.t()
        }
end
