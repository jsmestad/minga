defmodule Minga.RenderModel.Window.Row do
  @moduledoc """
  A semantic visual row with an injective retained-render identity.

  Row ids use the fixed unsigned 64-bit layout `kind:4 | source_id:32 |
  row_slot:28`. Producers must allocate stable row slots; this module never
  hashes, truncates, or derives a positional fallback.
  """

  import Bitwise

  alias Minga.RenderModel.Window.Span

  @kind_shift 60
  @source_shift 28
  @max_source_id 0xFFFF_FFFF
  @max_row_slot 0x0FFF_FFFF

  @enforce_keys [:row_id, :row_type, :buf_line, :text, :spans]
  defstruct row_id: 0,
            row_type: :normal,
            buf_line: 0,
            visual_index: 0,
            text: "",
            spans: [],
            content_hash: 0

  @type row_type :: :normal | :fold_start | :virtual_line | :block | :wrap_continuation
  @type identity_kind ::
          :normal
          | :wrap_continuation
          | :fold_start
          | :virtual_line
          | :block
          | :decoration_fold
  @type row_id :: 0..0xFFFF_FFFF_FFFF_FFFF
  @type row_slot :: 0..0x0FFF_FFFF

  @type t :: %__MODULE__{
          row_id: row_id(),
          row_type: row_type(),
          buf_line: non_neg_integer(),
          visual_index: non_neg_integer(),
          text: String.t(),
          spans: [Span.t()],
          content_hash: non_neg_integer()
        }

  @doc "Builds an injective row id from identity kind, durable source, and stable slot."
  @spec stable_id(identity_kind(), non_neg_integer(), row_slot()) :: row_id()
  def stable_id(kind, source_id, row_slot \\ 0)
      when source_id >= 0 and source_id <= @max_source_id and row_slot >= 0 and
             row_slot <= @max_row_slot do
    kind_bits = identity_kind_tag(kind) <<< @kind_shift
    source_bits = source_id <<< @source_shift
    kind_bits ||| source_bits ||| row_slot
  end

  @doc "Builds a decoration identity; `row_slot` must be producer-allocated integer state."
  @spec stable_decoration_id(row_type(), non_neg_integer(), row_slot()) :: row_id()
  def stable_decoration_id(row_type, source_id, row_slot) when is_integer(row_slot) do
    stable_id(decoration_kind(row_type), source_id, row_slot)
  end

  @doc "Updates transient positional metadata while preserving semantic identity and content."
  @spec reposition(t(), non_neg_integer()) :: t()
  def reposition(%__MODULE__{} = row, buf_line) when is_integer(buf_line) and buf_line >= 0 do
    %{row | buf_line: buf_line}
  end

  @doc "Computes a content hash for cache invalidation, not identity."
  @spec compute_hash(String.t(), [Span.t()]) :: non_neg_integer()
  def compute_hash(text, spans), do: :erlang.phash2({text, spans})

  @spec decoration_kind(row_type()) :: identity_kind()
  defp decoration_kind(:fold_start), do: :decoration_fold
  defp decoration_kind(:virtual_line), do: :virtual_line
  defp decoration_kind(:block), do: :block
  defp decoration_kind(other), do: other

  @spec identity_kind_tag(identity_kind()) :: 1..6
  defp identity_kind_tag(:normal), do: 1
  defp identity_kind_tag(:wrap_continuation), do: 2
  defp identity_kind_tag(:fold_start), do: 3
  defp identity_kind_tag(:virtual_line), do: 4
  defp identity_kind_tag(:block), do: 5
  defp identity_kind_tag(:decoration_fold), do: 6
end
