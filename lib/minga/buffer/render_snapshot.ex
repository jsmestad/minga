defmodule Minga.Buffer.RenderSnapshot do
  @moduledoc """
  A bounded, version-qualified buffer line view for rendering.

  Unlike the historical render snapshot this value never contains a
  `Minga.Buffer.Document`. `lines` contains only the range requested from the
  buffer process. Renderer callers first atomically consume the ChangeLog and
  then fetch a range at that exact version; a concurrent edit returns `:stale`.
  """

  alias Minga.Buffer.State, as: BufState

  @enforce_keys [
    :cursor,
    :line_count,
    :lines,
    :first_line,
    :file_path,
    :filetype,
    :buffer_type,
    :dirty,
    :name,
    :read_only,
    :first_line_byte_offset,
    :version,
    :options,
    :decorations,
    :change_sequence
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          cursor: Minga.Buffer.Document.position(),
          line_count: pos_integer(),
          lines: [String.t()],
          first_line: non_neg_integer(),
          file_path: String.t() | nil,
          filetype: atom(),
          buffer_type: BufState.buffer_type(),
          dirty: boolean(),
          name: String.t() | nil,
          read_only: boolean(),
          first_line_byte_offset: non_neg_integer(),
          version: non_neg_integer(),
          options: %{atom() => term()},
          decorations: Minga.Core.Decorations.t(),
          change_sequence: non_neg_integer()
        }
end
