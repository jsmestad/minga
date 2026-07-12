defmodule Minga.Buffer.RenderSnapshot do
  @moduledoc """
  Atomic render and change-lineage snapshot from a buffer process.

  The immutable document, metadata, version, line count, change horizon, and
  sequence-qualified deltas are captured in one GenServer call. `slice/3`
  derives range views without observing a newer buffer state.
  """

  alias Minga.Buffer.ChangeLog
  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.Lines
  alias Minga.Buffer.Position
  alias Minga.Buffer.State, as: BufState

  @type changes :: {:ok, [EditDelta.t()]} | :reset_required

  @enforce_keys [
    :document,
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
    :version,
    :options,
    :decorations,
    :change_sequence,
    :change_horizon,
    :changes
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          document: Document.t(),
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
          version: non_neg_integer(),
          options: %{atom() => term()},
          decorations: Minga.Core.Decorations.t(),
          change_sequence: ChangeLog.sequence(),
          change_horizon: ChangeLog.sequence(),
          changes: changes()
        }

  @doc "Returns a range view derived from the same immutable document snapshot."
  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: t()
  def slice(%__MODULE__{document: document} = snapshot, first_line, count)
      when first_line >= 0 and count >= 0 do
    lines = if count == 0, do: [], else: Lines.slice(document, first_line, count)

    %{
      snapshot
      | lines: lines,
        first_line_byte_offset: Position.point_for(document, {first_line, 0})
    }
  end
end
