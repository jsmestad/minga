defmodule Minga.Buffer.State do
  @moduledoc """
  Internal state for the Buffer GenServer.

  Holds the gap buffer, file path, dirty flag, and undo/redo stacks.
  """

  alias Minga.Buffer.GapBuffer

  @enforce_keys [:gap_buffer]
  defstruct gap_buffer: nil,
            file_path: nil,
            dirty: false,
            undo_stack: [],
            redo_stack: []

  @type t :: %__MODULE__{
          gap_buffer: GapBuffer.t(),
          file_path: String.t() | nil,
          dirty: boolean(),
          undo_stack: [GapBuffer.t()],
          redo_stack: [GapBuffer.t()]
        }
end
