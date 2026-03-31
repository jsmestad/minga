defmodule MingaEditor.SemanticWindow.Span do
  @moduledoc """
  A highlight span with pre-resolved colors and attributes.

  Spans reference display columns in the composed text (after virtual text
  splicing and conceal application). The GUI frontend applies these spans
  directly when building NSAttributedString; it never maps syntax tokens
  to theme colors.

  ## Attributes byte layout

  The `attrs` field packs boolean flags into a single byte:

  - bit 0: bold
  - bit 1: italic
  - bit 2: underline
  - bit 3: strikethrough
  - bit 4: underline_curl (wavy diagnostic underline)
  """

  @enforce_keys [:start_col, :end_col, :fg, :bg, :attrs]
  defstruct start_col: 0,
            end_col: 0,
            fg: 0,
            bg: 0,
            attrs: 0,
            font_weight: 0,
            font_id: 0

  @type t :: %__MODULE__{
          start_col: non_neg_integer(),
          end_col: non_neg_integer(),
          fg: non_neg_integer(),
          bg: non_neg_integer(),
          attrs: non_neg_integer(),
          font_weight: non_neg_integer(),
          font_id: non_neg_integer()
        }

  @doc "Builds a span from a `Face.t()` struct and column range."
  @spec from_face(Minga.Core.Face.t(), non_neg_integer(), non_neg_integer()) :: t()
  def from_face(%Minga.Core.Face{} = face, start_col, end_col) do
    import Bitwise

    attrs =
      if(face.bold, do: 1, else: 0) ||| if(face.italic, do: 1 <<< 1, else: 0) |||
        (if(face.underline, do: 1 <<< 2, else: 0) |||
           if(face.strikethrough, do: 1 <<< 3, else: 0)) |||
        if(face.underline_style == :curl, do: 1 <<< 4, else: 0)

    font_weight = encode_font_weight(face.font_weight)
    font_id = encode_font_id(face.font_family)

    %__MODULE__{
      start_col: start_col,
      end_col: end_col,
      fg: face.fg || 0,
      bg: face.bg || 0,
      attrs: attrs,
      font_weight: font_weight,
      font_id: font_id
    }
  end

  @spec encode_font_weight(Minga.Core.Face.font_weight() | nil) :: non_neg_integer()
  defp encode_font_weight(nil), do: 0
  defp encode_font_weight(:thin), do: 1
  defp encode_font_weight(:light), do: 2
  defp encode_font_weight(:regular), do: 3
  defp encode_font_weight(:medium), do: 4
  defp encode_font_weight(:bold), do: 5
  defp encode_font_weight(:black), do: 6

  # Font ID resolution: checks the process dictionary for the emit font
  # registry (set during the Emit stage). Returns 0 (default font) when
  # no registry is available or the family isn't registered.
  @spec encode_font_id(String.t() | nil) :: non_neg_integer()
  defp encode_font_id(nil), do: 0

  defp encode_font_id(family) when is_binary(family) do
    case Process.get(:emit_font_registry) do
      nil -> 0
      registry -> Map.get(registry, family, 0)
    end
  end
end
