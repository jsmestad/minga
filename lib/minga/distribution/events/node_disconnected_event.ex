defmodule Minga.Distribution.Events.NodeDisconnectedEvent do
  @moduledoc "Broadcast when a configured remote node disconnects."

  @enforce_keys [:server_name, :node, :reason, :disconnected_at]
  defstruct [:server_name, :node, :reason, :disconnected_at]

  @type t :: %__MODULE__{
          server_name: String.t(),
          node: node(),
          reason: term(),
          disconnected_at: DateTime.t()
        }
end
