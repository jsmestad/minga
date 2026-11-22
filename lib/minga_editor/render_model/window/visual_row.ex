defmodule MingaEditor.RenderModel.Window.VisualRow do
  @moduledoc "Internal retained visual-row entry for semantic window builds."

  alias Minga.Core.Unicode
  alias Minga.Core.Decorations.BlockDecoration
  alias Minga.RenderModel.Window.Row
  alias MingaEditor.RenderModel.Window.SourceOffsetMap

  @enforce_keys ~w(row buf_line visual_index display_row source_text source_offset_map source_start_byte source_end_byte source_start_col source_end_col composed_start_utf16 composed_end_utf16 indent_width row_width)a
  defstruct @enforce_keys ++
              [input_hash: nil, reused?: false, wrap_line_hash: nil, block_click: nil]

  @type block_target ::
          {:block_action, BlockDecoration.click_fn(), non_neg_integer(), non_neg_integer()}

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
          wrap_line_hash: non_neg_integer() | nil,
          block_click: {BlockDecoration.click_fn(), non_neg_integer()} | nil
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

  @doc "Retains the click callback for this rendered block line."
  @spec with_block_click(t(), BlockDecoration.click_fn(), non_neg_integer()) :: t()
  def with_block_click(%__MODULE__{} = row, click, line) when is_function(click, 2),
    do: %{row | block_click: {click, line}}

  def with_block_click(%__MODULE__{} = row, nil, _line), do: row

  @doc "Resolves a block hit from the committed row, not from live decorations."
  @spec block_target(t(), non_neg_integer()) :: block_target() | nil
  def block_target(%__MODULE__{block_click: nil}, _offset), do: nil

  def block_target(%__MODULE__{block_click: {click, line}, row: row, row_width: width}, offset) do
    col = display_col_for_utf16(row.text, offset, 0, 0)
    if col < width, do: {:block_action, click, line, col}
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
  def reposition(%__MODULE__{buf_line: line} = entry, line), do: entry

  def reposition(%__MODULE__{row: row} = entry, buf_line),
    do: %{entry | buf_line: buf_line, row: Row.reposition(row, buf_line)}

  @spec retained_row(t()) :: {Row.row_id(), {non_neg_integer(), Row.t()}}
  def retained_row(%__MODULE__{row: row, input_hash: input_hash}),
    do: {row.row_id, {input_hash || row.content_hash, row}}

  @spec reused?(t()) :: boolean()
  def reused?(%__MODULE__{reused?: reused?}), do: reused?

  @doc "Uses actual continuation source and synthetic wrap indent for guides."
  @spec guide_source_line(t()) :: String.t()
  def guide_source_line(%__MODULE__{row: %Row{row_type: :wrap_continuation}} = entry) do
    source =
      binary_part(
        entry.source_text,
        entry.source_start_byte,
        entry.source_end_byte - entry.source_start_byte
      )

    String.duplicate(" ", entry.indent_width) <> source
  end

  def guide_source_line(%__MODULE__{source_text: text}), do: text

  @doc "Returns the exclusive source end of the editor character at a grapheme boundary."
  @spec source_character_end(t(), non_neg_integer()) :: non_neg_integer()
  def source_character_end(%__MODULE__{source_text: text}, byte) when byte >= byte_size(text),
    do: byte_size(text)

  def source_character_end(%__MODULE__{source_text: text}, byte) do
    {grapheme, _rest} = String.next_grapheme(binary_part(text, byte, byte_size(text) - byte))
    byte + byte_size(grapheme)
  end

  @doc "Projects a source byte to a display column, including continuation indentation."
  @spec display_col(t(), non_neg_integer(), SourceOffsetMap.affinity()) :: non_neg_integer()
  def display_col(%__MODULE__{} = entry, byte, affinity) do
    composed = SourceOffsetMap.source_to_composed_utf16(entry.source_offset_map, byte, affinity)
    display_col_at_composed(entry, composed)
  end

  @doc "Projects an unmodified source slice without scanning the logical line prefix."
  @spec plain_source_display_col(t(), non_neg_integer()) :: non_neg_integer()
  def plain_source_display_col(%__MODULE__{} = entry, byte) do
    length = entry.source_end_byte - entry.source_start_byte
    text = binary_part(entry.source_text, entry.source_start_byte, length)

    entry.indent_width +
      display_col_for_byte(text, byte - entry.source_start_byte, 0, 0)
  end

  defp display_col_for_byte("", _target, _current, col), do: col
  defp display_col_for_byte(_text, target, current, col) when current >= target, do: col

  defp display_col_for_byte(text, target, current, col) do
    {grapheme, rest} = String.next_grapheme(text)
    next = current + byte_size(grapheme)

    if next > target,
      do: col,
      else: display_col_for_byte(rest, target, next, col + Unicode.grapheme_width(grapheme))
  end

  @spec display_col_at_composed(t(), non_neg_integer()) :: non_neg_integer()
  def display_col_at_composed(%__MODULE__{} = entry, composed) do
    local = entry.indent_width + composed - entry.composed_start_utf16
    display_col_for_utf16(entry.row.text, max(local, 0), 0, 0)
  end

  defp display_col_for_utf16("", _target, _utf16, col), do: col
  defp display_col_for_utf16(_text, target, utf16, col) when target <= utf16, do: col

  defp display_col_for_utf16(text, target, utf16, col) do
    {grapheme, rest} = String.next_grapheme(text)
    next_utf16 = utf16_length(grapheme, utf16)

    if next_utf16 > target,
      do: col,
      else:
        display_col_for_utf16(rest, target, next_utf16, col + Unicode.grapheme_width(grapheme))
  end

  defp utf16_length(<<>>, units), do: units

  defp utf16_length(<<cp::utf8, rest::binary>>, units),
    do: utf16_length(rest, units + if(cp > 0xFFFF, do: 2, else: 1))

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
