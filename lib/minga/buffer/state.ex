defmodule Minga.Buffer.State do
  @moduledoc """
  Internal state for the Buffer GenServer.

  Holds the gap buffer, file path, dirty flag, and undo/redo stacks.
  """

  alias Minga.Buffer.GapBuffer

  @enforce_keys [:gap_buffer]
  defstruct gap_buffer: nil,
            file_path: nil,
            filetype: :text,
            dirty: false,
            mtime: nil,
            file_size: nil,
            undo_stack: [],
            redo_stack: []

  @type t :: %__MODULE__{
          gap_buffer: GapBuffer.t(),
          file_path: String.t() | nil,
          filetype: atom(),
          dirty: boolean(),
          mtime: integer() | nil,
          file_size: non_neg_integer() | nil,
          undo_stack: [GapBuffer.t()],
          redo_stack: [GapBuffer.t()]
        }

  @max_undo_stack 1000

  @doc "Marks the buffer as having unsaved changes."
  @spec mark_dirty(t()) :: t()
  def mark_dirty(%__MODULE__{} = state), do: %{state | dirty: true}

  @doc """
  Pushes the current gap buffer onto the undo stack and replaces it with
  `new_buf`. Clears the redo stack. The undo stack is capped at
  #{@max_undo_stack} entries.
  """
  @spec push_undo(t(), GapBuffer.t()) :: t()
  def push_undo(%__MODULE__{} = state, new_buf) do
    new_undo =
      [state.gap_buffer | state.undo_stack]
      |> Enum.take(@max_undo_stack)

    %{state | gap_buffer: new_buf, undo_stack: new_undo, redo_stack: []}
  end
end
