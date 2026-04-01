defmodule Minga.Extension.UpdatesAvailableEvent do
  @moduledoc "Payload for `:extension_updates_available` events."
  @enforce_keys [:updates]
  defstruct [:updates]

  @type t :: %__MODULE__{
          updates: [map()]
        }
end
