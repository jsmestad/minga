defmodule Minga.Buffer.SyncSnapshot do
  @moduledoc """
  Atomic parser synchronization snapshot produced by a buffer process.

  The sequence and payload are captured in the same buffer mailbox turn. A token lets asynchronous consumers reject responses from superseded requests.
  """

  alias Minga.Buffer.ChangeLog
  alias Minga.Buffer.EditDelta

  @type changes :: {:full, String.t()} | {:edits, [EditDelta.t()]} | :unchanged

  @enforce_keys [:buffer, :token, :sequence, :changes]
  defstruct [:buffer, :token, :sequence, :changes]

  @type t :: %__MODULE__{
          buffer: pid(),
          token: reference(),
          sequence: ChangeLog.sequence(),
          changes: changes()
        }
end
