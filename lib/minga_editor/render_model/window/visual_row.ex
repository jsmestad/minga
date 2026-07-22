defmodule MingaEditor.RenderModel.Window.VisualRow do
  @moduledoc "Internal retained visual-row entry for semantic window builds."

  alias Minga.Core.Unicode
  alias Minga.RenderModel.Window.Row

  @enforce_keys ~w(row buf_line visual_index display_row source_text source_start_byte source_end_byte source_start_col source_end_col indent_width row_width)a
  defstruct @enforce_keys ++ [input_hash: nil, reused?: false, wrap_line_hash: nil]

  @type t :: %__MODULE__{
          row: Row.t(),
          buf_line: non_neg_integer(),
          visual_index: non_neg_integer(),
          display_row: non_neg_integer(),
          source_text: String.t(),
          source_start_byte: non_neg_integer(),
          source_end_byte: non_neg_integer(),
          source_start_col: non_neg_integer(),
          source_end_col: non_neg_integer(),
          indent_width: non_neg_integer(),
          row_width: non_neg_integer(),
          input_hash: non_neg_integer() | nil,
          reused?: boolean(),
          wrap_line_hash: non_neg_integer() | nil
        }

  @spec new(
          Row.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def new(
        %Row{} = row,
        source_text,
        source_start_col,
        source_end_col,
        source_start_byte,
        source_end_byte,
        indent_width
      ) do
    %__MODULE__{
      row: row,
      buf_line: row.buf_line,
      visual_index: row.visual_index,
      display_row: 0,
      source_text: source_text,
      source_start_byte: source_start_byte,
      source_end_byte: source_end_byte,
      source_start_col: source_start_col,
      source_end_col: source_end_col,
      indent_width: indent_width,
      row_width: Unicode.display_width(row.text)
    }
  end

  @spec with_display_row(t(), non_neg_integer()) :: t()
  def with_display_row(%__MODULE__{} = entry, display_row),
    do: %{entry | display_row: display_row}

  @spec with_retention(t(), non_neg_integer(), boolean()) :: t()
  def with_retention(%__MODULE__{} = entry, input_hash, reused?),
    do: %{entry | input_hash: input_hash, reused?: reused?}

  @spec with_wrap_line_hash(t(), non_neg_integer()) :: t()
  def with_wrap_line_hash(%__MODULE__{} = entry, wrap_line_hash),
    do: %{entry | wrap_line_hash: wrap_line_hash}

  @spec reposition(t(), non_neg_integer()) :: t()
  def reposition(%__MODULE__{row: row} = entry, buf_line),
    do: %{entry | buf_line: buf_line, row: Row.reposition(row, buf_line)}

  @spec retained_row(t()) :: {Row.row_id(), {non_neg_integer(), Row.t()}}
  def retained_row(%__MODULE__{row: row, input_hash: input_hash}),
    do: {row.row_id, {input_hash || row.content_hash, row}}

  @spec reused?(t()) :: boolean()
  def reused?(%__MODULE__{reused?: reused?}), do: reused?
end
