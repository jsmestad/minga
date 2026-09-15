defmodule Minga.FileWatcher.ReadyEvent do
  @moduledoc "Payload published when a FileWatcher process is ready for authority reconstruction."

  @enforce_keys [:watcher]
  defstruct [:watcher]

  @type t :: %__MODULE__{watcher: pid()}
end
