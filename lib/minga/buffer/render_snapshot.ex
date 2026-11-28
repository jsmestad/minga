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
  defstruct [{:extra_ranges, []} | @enforce_keys]

  @typedoc """
  A further changed line range read in the same buffer call: its first line, that line's byte offset,
  and its lines. Ranges are ascending, disjoint, and all after `lines`.
  """
  @type extra_range ::
          {first_line :: non_neg_integer(), first_line_byte_offset :: non_neg_integer(),
           lines :: [String.t()]}

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
          change_sequence: non_neg_integer(),
          extra_ranges: [extra_range()]
        }

  @doc "Returns every line range the snapshot holds, ascending."
  @spec line_ranges(t()) :: [{non_neg_integer(), non_neg_integer()}]
  def line_ranges(%__MODULE__{first_line: first, lines: lines, extra_ranges: extras}) do
    extra =
      for {extra_first, _offset, extra_lines} <- extras, do: range_of(extra_first, extra_lines)

    if lines == [], do: extra, else: [range_of(first, lines) | extra]
  end

  @spec range_of(non_neg_integer(), [String.t()]) :: {non_neg_integer(), non_neg_integer()}
  defp range_of(first, lines), do: {first, first + max(length(lines) - 1, 0)}
end
