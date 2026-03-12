defmodule Minga.NavigableContent.BufferSnapshot do
  @moduledoc """
  NavigableContent adapter for `Buffer.Document` snapshots.

  Wraps a `Document.t()` and a `Scroll.t()` into a single struct that
  implements both `NavigableContent` and `Readable`. This is the bridge
  between the Buffer domain (gap buffer, byte-indexed columns, undo
  stack) and the universal editing model (protocol-based commands).

  ## Usage

      # Take a snapshot from a running Buffer.Server
      doc = Buffer.Server.snapshot(server)
      snapshot = BufferSnapshot.new(doc, scroll)

      # Commands operate on the snapshot
      pos = Motion.word_forward(snapshot, NavigableContent.cursor(snapshot))
      snapshot = NavigableContent.set_cursor(snapshot, pos)

      # Apply the result back
      Buffer.Server.apply_snapshot(server, snapshot.document)

  ## Coordinate system

  Columns are byte offsets, matching `Document`'s convention. This is
  consistent with tree-sitter and the Zig renderer. Use
  `Document.grapheme_col/2` when you need display column widths.
  """

  alias Minga.Buffer.Document
  alias Minga.Scroll

  @typedoc "A Document snapshot with scroll state for NavigableContent."
  @type t :: %__MODULE__{
          document: Document.t(),
          scroll: Scroll.t()
        }

  @enforce_keys [:document]
  defstruct document: nil,
            scroll: %Scroll{}

  @doc "Creates a new BufferSnapshot from a Document and optional Scroll state."
  @spec new(Document.t()) :: t()
  def new(%Document{} = doc), do: %__MODULE__{document: doc}

  @spec new(Document.t(), Scroll.t()) :: t()
  def new(%Document{} = doc, %Scroll{} = scroll) do
    %__MODULE__{document: doc, scroll: scroll}
  end
end

# ── NavigableContent implementation ──────────────────────────────────────────

defimpl Minga.NavigableContent, for: Minga.NavigableContent.BufferSnapshot do
  @moduledoc false

  alias Minga.Buffer.Document
  alias Minga.NavigableContent.BufferSnapshot

  @spec cursor(BufferSnapshot.t()) :: Minga.NavigableContent.position()
  def cursor(%BufferSnapshot{document: doc}), do: Document.cursor(doc)

  @spec set_cursor(BufferSnapshot.t(), Minga.NavigableContent.position()) :: BufferSnapshot.t()
  def set_cursor(%BufferSnapshot{document: doc} = snapshot, position) do
    %{snapshot | document: Document.move_to(doc, position)}
  end

  @spec editable?(BufferSnapshot.t()) :: boolean()
  def editable?(%BufferSnapshot{}), do: true

  @spec replace_range(
          BufferSnapshot.t(),
          Minga.NavigableContent.position(),
          Minga.NavigableContent.position(),
          String.t()
        ) :: BufferSnapshot.t()
  def replace_range(%BufferSnapshot{document: doc} = snapshot, start_pos, end_pos, text) do
    new_doc =
      if start_pos == end_pos do
        # Pure insert at position
        doc
        |> Document.move_to(start_pos)
        |> Document.insert_text(text)
      else
        # Delete range, then insert replacement
        deleted = Document.delete_range(doc, start_pos, end_pos)

        if text == "" do
          deleted
        else
          deleted
          |> Document.move_to(start_pos)
          |> Document.insert_text(text)
        end
      end

    %{snapshot | document: new_doc}
  end

  @spec scroll(BufferSnapshot.t()) :: Minga.Scroll.t()
  def scroll(%BufferSnapshot{scroll: scroll}), do: scroll

  @spec set_scroll(BufferSnapshot.t(), Minga.Scroll.t()) :: BufferSnapshot.t()
  def set_scroll(%BufferSnapshot{} = snapshot, scroll) do
    %{snapshot | scroll: scroll}
  end

  @spec search_forward(BufferSnapshot.t(), String.t(), Minga.NavigableContent.position()) ::
          Minga.NavigableContent.position() | nil
  def search_forward(%BufferSnapshot{document: doc}, pattern, {from_line, from_col}) do
    total = Document.line_count(doc)
    search_forward_from(doc, pattern, from_line, from_col, total, 0, false)
  end

  @spec search_backward(BufferSnapshot.t(), String.t(), Minga.NavigableContent.position()) ::
          Minga.NavigableContent.position() | nil
  def search_backward(%BufferSnapshot{document: doc}, pattern, {from_line, from_col}) do
    total = Document.line_count(doc)
    search_backward_from(doc, pattern, from_line, from_col, total, total - 1, false)
  end

  # ── Forward search helpers ─────────────────────────────────────────────────

  # Empty pattern never matches.
  defp search_forward_from(_doc, "", _line, _col, _total, _wrap_stop, _wrapped), do: nil

  # Wrapped past the starting line: no match found.
  defp search_forward_from(_doc, _pattern, line, _col, _total, wrap_stop, true)
       when line > wrap_stop,
       do: nil

  defp search_forward_from(doc, pattern, line, col, total, wrap_stop, wrapped) do
    line_text = Document.line_at(doc, min(line, total - 1))
    match_result = match_forward_in_line(line_text, pattern, col + 1)
    advance_forward(match_result, doc, pattern, line, total, wrap_stop, wrapped)
  end

  defp match_forward_in_line(nil, _pattern, _search_col), do: :no_line
  defp match_forward_in_line(text, _pattern, col) when col >= byte_size(text), do: :nomatch

  defp match_forward_in_line(text, pattern, search_col) do
    suffix = binary_part(text, search_col, byte_size(text) - search_col)

    case :binary.match(suffix, pattern) do
      {offset, _len} -> {:found, search_col + offset}
      :nomatch -> :nomatch
    end
  end

  defp advance_forward({:found, col}, _doc, _pattern, line, _total, _wrap_stop, _wrapped) do
    {line, col}
  end

  defp advance_forward(:no_line, _doc, _pattern, _line, _total, _wrap_stop, _wrapped), do: nil

  # No match on this line, more lines ahead.
  defp advance_forward(:nomatch, doc, pattern, line, total, wrap_stop, wrapped)
       when line + 1 < total do
    search_forward_from(doc, pattern, line + 1, -1, total, wrap_stop, wrapped)
  end

  # Hit the end of content, already wrapped: give up.
  defp advance_forward(:nomatch, _doc, _pattern, _line, _total, _wrap_stop, true), do: nil

  # Hit the end, wrap to beginning.
  defp advance_forward(:nomatch, doc, pattern, line, total, _wrap_stop, false) do
    search_forward_from(doc, pattern, 0, -1, total, line, true)
  end

  # ── Backward search helpers ────────────────────────────────────────────────

  defp search_backward_from(_doc, "", _line, _col, _total, _wrap_stop, _wrapped), do: nil

  defp search_backward_from(_doc, _pattern, line, _col, _total, wrap_stop, true)
       when line < wrap_stop,
       do: nil

  defp search_backward_from(doc, pattern, line, col, total, wrap_stop, wrapped) do
    line_text = Document.line_at(doc, max(line, 0))
    match_result = match_backward_in_line(line_text, pattern, col)
    advance_backward(match_result, doc, pattern, line, total, wrap_stop, wrapped)
  end

  defp match_backward_in_line(nil, _pattern, _col), do: :no_line

  defp match_backward_in_line(text, pattern, :end) do
    find_last_match(text, pattern)
  end

  defp match_backward_in_line(text, pattern, col) do
    prefix_len = min(col, byte_size(text))
    prefix = binary_part(text, 0, prefix_len)
    find_last_match(prefix, pattern)
  end

  defp advance_backward({:found, offset}, _doc, _pattern, line, _total, _wrap_stop, _wrapped) do
    {line, offset}
  end

  defp advance_backward(:no_line, _doc, _pattern, _line, _total, _wrap_stop, _wrapped), do: nil

  # No match on this line, more lines above.
  defp advance_backward(:not_found, doc, pattern, line, total, wrap_stop, wrapped)
       when line - 1 >= 0 do
    search_backward_from(doc, pattern, line - 1, :end, total, wrap_stop, wrapped)
  end

  # Hit the top, already wrapped: give up.
  defp advance_backward(:not_found, _doc, _pattern, _line, _total, _wrap_stop, true), do: nil

  # Hit the top, wrap to end.
  defp advance_backward(:not_found, doc, pattern, line, total, _wrap_stop, false) do
    search_backward_from(doc, pattern, total - 1, :end, total, line, true)
  end

  # ── String helpers ─────────────────────────────────────────────────────────

  # Find the last occurrence of pattern in text. Returns {:found, offset} or :not_found.
  defp find_last_match("", _pattern), do: :not_found

  defp find_last_match(text, pattern) do
    find_last_match_acc(text, pattern, 0, :not_found)
  end

  defp find_last_match_acc(text, _pattern, offset, last_found) when offset >= byte_size(text) do
    last_found
  end

  defp find_last_match_acc(text, pattern, offset, last_found) do
    suffix = binary_part(text, offset, byte_size(text) - offset)

    case :binary.match(suffix, pattern) do
      {pos, _len} ->
        absolute = offset + pos
        find_last_match_acc(text, pattern, absolute + 1, {:found, absolute})

      :nomatch ->
        last_found
    end
  end
end

# ── Readable delegation ─────────────────────────────────────────────────────

defimpl Minga.Text.Readable, for: Minga.NavigableContent.BufferSnapshot do
  @moduledoc false

  alias Minga.Buffer.Document
  alias Minga.NavigableContent.BufferSnapshot

  @spec content(BufferSnapshot.t()) :: String.t()
  def content(%BufferSnapshot{document: doc}), do: Document.content(doc)

  @spec line_at(BufferSnapshot.t(), non_neg_integer()) :: String.t() | nil
  def line_at(%BufferSnapshot{document: doc}, n), do: Document.line_at(doc, n)

  @spec line_count(BufferSnapshot.t()) :: pos_integer()
  def line_count(%BufferSnapshot{document: doc}), do: Document.line_count(doc)

  @spec offset_to_position(BufferSnapshot.t(), non_neg_integer()) ::
          Minga.Text.Readable.position()
  def offset_to_position(%BufferSnapshot{document: doc}, offset) do
    Document.offset_to_position(doc, offset)
  end
end
