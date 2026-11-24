defmodule MingaAgent.MCP.Transport do
  @moduledoc """
  Transport behaviour used by the session-scoped MCP client.

  Production uses a JSON-lines stdio port. Tests inject an in-BEAM transport
  that implements the same synchronous request and notification API without
  spawning OS processes.

  The transport value holds all per-connection state, such as a partly received response frame. `request/3` and `handle_transport_info/2` return the next transport value. The owning client must install that value and pass it to the next call, so state that one call leaves behind (for example, the rest of a response that timed out) is still available to the next.
  """

  alias MingaAgent.MCP.ServerConfig

  @typedoc "Opaque transport state returned by `start/3` and by every call that can change it."
  @type t :: term()

  @typedoc "Outcome of one request, with the transport value that later calls must use."
  @type request_result :: {:ok, map(), t()} | {:error, term(), t()}

  @callback start(ServerConfig.t(), pid(), keyword()) :: {:ok, t()} | {:error, term()}
  @callback request(t(), map(), timeout()) :: request_result()
  @callback notify(t(), map()) :: :ok | {:error, term()}
  @callback stop(t()) :: :ok
  @callback handle_transport_info(term(), t()) :: {:ok, t()} | {:down, term()}
end
