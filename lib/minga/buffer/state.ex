defmodule Minga.Buffer.State do
  @moduledoc """
  Internal state for the Buffer GenServer.

  Holds the gap buffer, file path, dirty flag, and undo/redo stacks.
  """

  alias Minga.Buffer.Document

  @enforce_keys [:document]
  defstruct document: nil,
            file_path: nil,
            filetype: :text,
            dirty: false,
            version: 0,
            mtime: nil,
            file_size: nil,
            undo_stack: [],
            redo_stack: [],
            name: nil,
            read_only: false,
            unlisted: false,
            persistent: false

  @type t :: %__MODULE__{
          document: Document.t(),
          file_path: String.t() | nil,
          filetype: atom(),
          dirty: boolean(),
          version: non_neg_integer(),
          mtime: integer() | nil,
          file_size: non_neg_integer() | nil,
          undo_stack: [Document.t()],
          redo_stack: [Document.t()],
          name: String.t() | nil,
          read_only: boolean(),
          unlisted: boolean(),
          persistent: boolean()
        }

  @max_undo_stack 1000

  @doc "Marks the buffer as having unsaved changes."
  @spec mark_dirty(t()) :: t()
  def mark_dirty(%__MODULE__{} = state), do: %{state | dirty: true, version: state.version + 1}

  @doc """
  Pushes the current gap buffer onto the undo stack and replaces it with
  `new_buf`. Clears the redo stack. The undo stack is capped at
  #{@max_undo_stack} entries.
  """
  @spec push_undo(t(), Document.t()) :: t()
  def push_undo(%__MODULE__{} = state, new_buf) do
    new_undo =
      [state.document | state.undo_stack]
      |> Enum.take(@max_undo_stack)

    %{state | document: new_buf, undo_stack: new_undo, redo_stack: []}
  end
end
