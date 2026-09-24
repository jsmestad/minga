defmodule MingaEditor.RenderModel.Window.VisualRow do
  @moduledoc "Internal retained visual-row entry for semantic window builds."

  alias Minga.Core.Unicode
  alias Minga.RenderModel.Window.Row
  alias MingaEditor.RenderModel.Window.SourceOffsetMap

  @enforce_keys ~w(row buf_line visual_index display_row source_text source_offset_map source_start_byte source_end_byte source_start_col source_end_col composed_start_utf16 composed_end_utf16 indent_width row_width)a
  defstruct @enforce_keys ++ [input_hash: nil, reused?: false, wrap_line_hash: nil]

  @type t :: %__MODULE__{
          row: Row.t(),
          buf_line: non_neg_integer(),
          visual_index: non_neg_integer(),
          display_row: non_neg_integer(),
          source_text: String.t(),
          source_offset_map: SourceOffsetMap.t(),
          source_start_byte: non_neg_integer(),
          source_end_byte: non_neg_integer(),
          source_start_col: non_neg_integer(),
          source_end_col: non_neg_integer(),
          composed_start_utf16: non_neg_integer(),
          composed_end_utf16: non_neg_integer(),
          indent_width: non_neg_integer(),
          row_width: non_neg_integer(),
          input_hash: non_neg_integer() | nil,
          reused?: boolean(),
          wrap_line_hash: non_neg_integer() | nil
        }

  @spec new(
          Row.t(),
          SourceOffsetMap.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def new(
        %Row{} = row,
        %SourceOffsetMap{} = source_offset_map,
        source_start_col,
        source_end_col,
        indent_width
      ) do
    %__MODULE__{
      row: row,
      buf_line: row.buf_line,
      visual_index: row.visual_index,
      display_row: 0,
      source_text: source_offset_map.source_text,
      source_offset_map: source_offset_map,
      source_start_byte: source_offset_map.source_start_byte,
      source_end_byte: source_offset_map.source_end_byte,
      source_start_col: source_start_col,
      source_end_col: source_end_col,
      composed_start_utf16: source_offset_map.composed_start_utf16,
      composed_end_utf16: source_offset_map.composed_end_utf16,
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

  @doc """
  Resolves a modal pointer target to a character in the displayed row.

  A hit at or beyond the row end targets its final composed grapheme, so a soft-wrap boundary does not select the next row's first character.
  The source map preserves Unicode grapheme boundaries, replacement ranges, and virtual-text anchors.
  Empty and non-source rows retain their existing boundary behavior.
  """
  @spec source_character_position(t(), non_neg_integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | :not_source_backed
  def source_character_position(
        %__MODULE__{
          composed_start_utf16: start_utf16,
          composed_end_utf16: end_utf16,
          indent_width: indent
        } = entry,
        row_local_utf16
      )
      when end_utf16 > start_utf16 and row_local_utf16 >= indent + end_utf16 - start_utf16,
      do: source_position(entry, indent + end_utf16 - start_utf16 - 1, :start)

  def source_character_position(%__MODULE__{} = entry, row_local_utf16),
    do: source_position(entry, row_local_utf16)

  @doc """
  Resolves a row-local composed UTF-16 boundary to a source position.

  Wrap indentation resolves to the row's first source byte. Offsets past the
  rendered row resolve to its final source byte. Inline virtual text resolves
  to its anchor, and fold-summary text resolves to source end-of-line.
  """
  @spec source_position(t(), non_neg_integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | :not_source_backed
  def source_position(%__MODULE__{} = entry, row_local_utf16) do
    source_position(entry, row_local_utf16, :start)
  end

  @doc """
  Resolves a row-local composed UTF-16 boundary with explicit affinity.

  Inside replacement text or a grapheme's UTF-16 range, `:start` chooses the
  preceding source boundary and `:end` chooses the following source boundary.
  """
  @spec source_position(t(), non_neg_integer(), SourceOffsetMap.affinity()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | :not_source_backed
  def source_position(
        %__MODULE__{row: %Row{row_type: row_type}},
        _row_local_utf16,
        _affinity
      )
      when row_type in [:virtual_line, :block],
      do: :not_source_backed

  def source_position(%__MODULE__{} = entry, row_local_utf16, affinity) do
    content_utf16 = entry.composed_end_utf16 - entry.composed_start_utf16

    content_local_utf16 =
      row_local_utf16 |> max(entry.indent_width) |> Kernel.-(entry.indent_width)

    composed_utf16 = entry.composed_start_utf16 + min(content_local_utf16, content_utf16)

    source_byte =
      entry.source_offset_map
      |> SourceOffsetMap.composed_utf16_to_source_byte(composed_utf16, affinity)
      |> max(entry.source_start_byte)
      |> min(entry.source_end_byte)

    {:ok, {entry.buf_line, source_byte}}
  end
end
