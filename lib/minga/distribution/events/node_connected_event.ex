defmodule Minga.Distribution.Events.NodeConnectedEvent do
  @moduledoc "Broadcast when a configured remote node connects."

  @enforce_keys [:server_name, :node, :connected_at]
  defstruct [:server_name, :node, :connected_at]

  @type t :: %__MODULE__{
          server_name: String.t(),
          node: node(),
          connected_at: DateTime.t()
        }
end
