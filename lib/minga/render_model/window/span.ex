defmodule Minga.RenderModel.Window.Span do
  @moduledoc """
  A highlight span with pre-resolved colors and attributes.

  Spans reference display columns in the composed text. They never resolve editor-local resources such as secondary font registrations; builders pass the already-resolved `font_id` when a span needs one.
  """

  import Bitwise

  alias Minga.Core.Face

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

  @doc "Builds a span from a `Face.t()` struct and display-column range."
  @spec from_face(Face.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def from_face(%Face{} = face, start_col, end_col, font_id \\ 0) do
    %__MODULE__{
      start_col: start_col,
      end_col: end_col,
      fg: face.fg || 0,
      bg: face.bg || 0,
      attrs: encode_attrs(face),
      font_weight: encode_font_weight(face),
      font_id: font_id
    }
  end

  @doc "Clips a span to a source display-column range and rebases it into a visual row."
  @spec rebase_to_visual_row(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: [
          t()
        ]
  def rebase_to_visual_row(%__MODULE__{} = span, source_start, source_end, indent_width) do
    start_col = max(span.start_col, source_start)
    end_col = min(span.end_col, source_end)

    if end_col > start_col do
      [
        %__MODULE__{
          span
          | start_col: start_col - source_start + indent_width,
            end_col: end_col - source_start + indent_width
        }
      ]
    else
      []
    end
  end

  @spec encode_attrs(Face.t()) :: non_neg_integer()
  defp encode_attrs(%Face{} = face) do
    if(face.bold, do: 1, else: 0) |||
      if(face.italic, do: 1 <<< 1, else: 0) |||
      if(face.underline, do: 1 <<< 2, else: 0) |||
      if(face.strikethrough, do: 1 <<< 3, else: 0) |||
      if(face.underline_style == :curl, do: 1 <<< 4, else: 0)
  end

  @spec encode_font_weight(Face.t()) :: non_neg_integer()
  defp encode_font_weight(%Face{font_weight: nil, bold: true}), do: 5
  defp encode_font_weight(%Face{font_weight: nil}), do: 2
  defp encode_font_weight(%Face{font_weight: :thin}), do: 0
  defp encode_font_weight(%Face{font_weight: :light}), do: 1
  defp encode_font_weight(%Face{font_weight: :regular}), do: 2
  defp encode_font_weight(%Face{font_weight: :medium}), do: 3
  defp encode_font_weight(%Face{font_weight: :semibold}), do: 4
  defp encode_font_weight(%Face{font_weight: :bold}), do: 5
  defp encode_font_weight(%Face{font_weight: :heavy}), do: 6
  defp encode_font_weight(%Face{font_weight: :black}), do: 7
end
