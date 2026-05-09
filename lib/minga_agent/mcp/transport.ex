defmodule MingaAgent.MCP.Transport do
  @moduledoc """
  Transport behaviour used by the session-scoped MCP client.

  Production uses a JSON-lines stdio port. Tests inject an in-BEAM transport
  that implements the same synchronous request and notification API without
  spawning OS processes.
  """

  alias MingaAgent.MCP.ServerConfig

  @typedoc "Opaque transport state returned by `start/3`."
  @type t :: term()

  @callback start(ServerConfig.t(), pid(), keyword()) :: {:ok, t()} | {:error, term()}
  @callback request(t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  @callback notify(t(), map()) :: :ok | {:error, term()}
  @callback stop(t()) :: :ok
  @callback handle_transport_info(term(), t()) :: :ignore | {:down, term()}
end
