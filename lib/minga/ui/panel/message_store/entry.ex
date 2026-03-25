defmodule Minga.UI.Panel.MessageStore.Entry do
  @moduledoc "A single structured log entry in the MessageStore."

  @type t :: %__MODULE__{
          id: pos_integer(),
          level: Minga.UI.Panel.MessageStore.level(),
          subsystem: Minga.UI.Panel.MessageStore.subsystem(),
          timestamp: NaiveDateTime.t(),
          text: String.t(),
          file_path: String.t() | nil
        }

  @enforce_keys [:id, :level, :subsystem, :timestamp, :text]
  defstruct [:id, :level, :subsystem, :timestamp, :text, :file_path]
end
