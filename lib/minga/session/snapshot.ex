defmodule Minga.Session.Snapshot do
  @moduledoc """
  A session snapshot capturing the editor's restorable state.

  Built from editor state when saving a session, and deserialized
  when restoring. Contains the list of open buffers with cursor
  positions and the active file path.
  """

  alias Minga.Session.BufferEntry

  @derive JSON.Encoder

  @typedoc "A session snapshot."
  @type t :: %__MODULE__{
          version: pos_integer(),
          buffers: [BufferEntry.t()],
          active_file: String.t() | nil,
          clean_shutdown: boolean()
        }

  @enforce_keys [:version]
  defstruct version: 1,
            buffers: [],
            active_file: nil,
            clean_shutdown: false
end
