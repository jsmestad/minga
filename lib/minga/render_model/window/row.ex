defmodule Minga.RenderModel.Window.Row do
  @moduledoc """
  A single visual row in the semantic window.

  Represents one display row as the GUI should render it. The BEAM has
  already resolved word wrap, folding, virtual text splicing, and conceal
  ranges. The `text` field contains the final composed UTF-8 string.

  ## Row Types

  - `:normal` — a regular buffer line (or the visible portion after wrapping)
  - `:fold_start` — a fold summary line (text includes the fold indicator)
  - `:virtual_line` — an injected virtual line from decorations (no buffer content)
  - `:block` — a block decoration row rendered by a callback
  - `:wrap_continuation` — a continuation row from word wrapping
  """

  import Bitwise

  alias Minga.RenderModel.Window.Span

  @row_id_kind_shift 60
  @row_id_line_shift 28
  @row_id_visual_shift 12
  @row_id_line_mask 0xFFFF_FFFF
  @row_id_visual_mask 0xFFFF
  @row_id_discriminator_mask 0x0FFF
  @row_id_discriminator_range @row_id_discriminator_mask + 1

  @enforce_keys [:row_type, :buf_line, :text, :spans]
  defstruct row_id: 0,
            row_type: :normal,
            buf_line: 0,
            visual_index: 0,
            text: "",
            spans: [],
            content_hash: 0

  @type row_type :: :normal | :fold_start | :virtual_line | :block | :wrap_continuation
  @type row_id :: non_neg_integer()

  @type t :: %__MODULE__{
          row_id: row_id(),
          row_type: row_type(),
          buf_line: non_neg_integer(),
          visual_index: non_neg_integer(),
          text: String.t(),
          spans: [Span.t()],
          content_hash: non_neg_integer()
        }

  @doc "Builds a compact, deterministic row identity for retained GUI texture reuse."
  @spec stable_id(row_type(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: row_id()
  def stable_id(row_type, buf_line, visual_index \\ 0, discriminator \\ 0) do
    kind_bits = row_type_tag(row_type) <<< @row_id_kind_shift
    line_bits = (buf_line &&& @row_id_line_mask) <<< @row_id_line_shift
    visual_bits = (visual_index &&& @row_id_visual_mask) <<< @row_id_visual_shift
    discriminator_bits = discriminator &&& @row_id_discriminator_mask

    kind_bits ||| line_bits ||| visual_bits ||| discriminator_bits
  end

  @doc "Returns a small discriminator suitable for the low bits of `stable_id/4`."
  @spec discriminator(term()) :: non_neg_integer()
  def discriminator(value), do: :erlang.phash2(value, @row_id_discriminator_range)

  @doc "Computes a content hash for cache invalidation."
  @spec compute_hash(String.t(), [Span.t()]) :: non_neg_integer()
  def compute_hash(text, spans) do
    :erlang.phash2({text, spans})
  end

  @spec row_type_tag(row_type()) :: non_neg_integer()
  defp row_type_tag(:normal), do: 1
  defp row_type_tag(:fold_start), do: 2
  defp row_type_tag(:virtual_line), do: 3
  defp row_type_tag(:block), do: 4
  defp row_type_tag(:wrap_continuation), do: 5
end
