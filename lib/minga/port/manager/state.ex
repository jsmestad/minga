defmodule Minga.Port.Manager.State do
  @moduledoc """
  Internal state for the Port Manager GenServer.

  Tracks the Zig renderer port, subscribers, readiness, and terminal dimensions.
  """

  @enforce_keys [:renderer_path]
  defstruct port: nil,
            subscribers: [],
            renderer_path: "",
            ready: false,
            terminal_size: nil

  @type t :: %__MODULE__{
          port: port() | nil,
          subscribers: [pid()],
          renderer_path: String.t(),
          ready: boolean(),
          terminal_size: {width :: pos_integer(), height :: pos_integer()} | nil
        }
end
