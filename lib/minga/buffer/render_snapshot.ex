defmodule Minga.Buffer.RenderSnapshot do
  @moduledoc """
  All data needed to render a single frame for one buffer.

  Constructed atomically inside `BufferServer.handle_call/3` so the
  caller gets a consistent snapshot of cursor, lines, metadata, and
  version in a single GenServer round-trip. Previously a bare map;
  promoted to a struct for compile-time field enforcement and better
  type-system support.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.State, as: BufState

  @enforce_keys [
    :cursor,
    :line_count,
    :lines,
    :file_path,
    :filetype,
    :buffer_type,
    :dirty,
    :name,
    :read_only,
    :first_line_byte_offset,
    :version
  ]

  defstruct [
    :cursor,
    :line_count,
    :lines,
    :file_path,
    :filetype,
    :buffer_type,
    :dirty,
    :name,
    :read_only,
    :first_line_byte_offset,
    :version
  ]

  @type t :: %__MODULE__{
          cursor: Document.position(),
          line_count: pos_integer(),
          lines: [String.t()],
          file_path: String.t() | nil,
          filetype: atom(),
          buffer_type: BufState.buffer_type(),
          dirty: boolean(),
          name: String.t() | nil,
          read_only: boolean(),
          first_line_byte_offset: non_neg_integer(),
          version: non_neg_integer()
        }
end
