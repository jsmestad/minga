defmodule Minga.Port.Frontend do
  @moduledoc """
  Behaviour for rendering frontends that communicate with the Editor.

  Any process that can receive encoded render commands and emit input
  events can serve as a Minga frontend. The Editor dispatches through
  this interface without knowing whether the other end is a libvaxis
  TUI, a native GUI, or a headless test harness.

  ## Implementations

  - `Minga.Port.Manager` — production frontend managing a Zig renderer Port
  - `Minga.Test.HeadlessPort` — in-memory screen grid for testing

  ## Contract

  Frontends receive pre-encoded binary commands via `send_commands/2`
  and deliver input events to subscribers as `{:minga_input, event}`
  messages. The event types are defined in `Minga.Port.Protocol`.
  """

  @doc "Starts the frontend process."
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Sends a list of pre-encoded render command binaries to the frontend.

  Commands are encoded via `Minga.Port.Protocol.encode_*` functions.
  The frontend processes them in order. A `batch_end` command signals
  the end of a frame and triggers a render flush.
  """
  @callback send_commands(server :: GenServer.server(), commands :: [binary()]) :: :ok

  @doc """
  Subscribes the calling process to receive input events.

  The subscriber will receive `{:minga_input, event}` messages where
  `event` is a `Minga.Port.Protocol.input_event()`.
  """
  @callback subscribe(server :: GenServer.server()) :: :ok

  @doc """
  Returns the frontend's screen dimensions as `{width, height}`.

  Returns `nil` if the frontend is not yet ready (e.g., the renderer
  has not sent its initial `ready` event).
  """
  @callback terminal_size(server :: GenServer.server()) ::
              {pos_integer(), pos_integer()} | nil

  @doc """
  Returns whether the frontend is ready to accept render commands.

  A frontend becomes ready after its initialization handshake completes
  (e.g., the Zig renderer sends a `ready` event with terminal dimensions).
  """
  @callback ready?(server :: GenServer.server()) :: boolean()

  @doc """
  Returns the frontend's reported capabilities.

  Capabilities are populated from the `ready` event (extended format)
  or from a subsequent `capabilities_updated` event. Returns default
  capabilities if the frontend has not reported any.
  """
  @callback capabilities(server :: GenServer.server()) :: Minga.Port.Capabilities.t()
end
