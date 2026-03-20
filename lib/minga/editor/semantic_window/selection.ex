defmodule Minga.Editor.SemanticWindow.Selection do
  @moduledoc """
  Visual selection overlay in display coordinates.

  Sent as coordinate ranges so the GUI can render selection as Metal
  quads behind text, avoiding line re-rasterization when the selection
  changes.
  """

  @enforce_keys [:type]
  defstruct type: :none,
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 0

  @type selection_type :: :char | :line | :block

  @type t :: %__MODULE__{
          type: selection_type(),
          start_row: non_neg_integer(),
          start_col: non_neg_integer(),
          end_row: non_neg_integer(),
          end_col: non_neg_integer()
        }

  @doc "Builds a selection from the render context's visual_selection."
  @spec from_visual_selection(
          nil
          | {:char, {non_neg_integer(), non_neg_integer()},
             {non_neg_integer(), non_neg_integer()}}
          | {:line, non_neg_integer(), non_neg_integer()},
          non_neg_integer()
        ) :: t() | nil
  def from_visual_selection(nil, _viewport_top), do: nil

  def from_visual_selection({:char, {sl, sc}, {el, ec}}, viewport_top) do
    %__MODULE__{
      type: :char,
      start_row: sl - viewport_top,
      start_col: sc,
      end_row: el - viewport_top,
      end_col: ec
    }
  end

  def from_visual_selection({:line, start_line, end_line}, viewport_top) do
    %__MODULE__{
      type: :line,
      start_row: start_line - viewport_top,
      start_col: 0,
      end_row: end_line - viewport_top,
      end_col: 0
    }
  end
end
