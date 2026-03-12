defprotocol Minga.NavigableContent do
  @moduledoc """
  Protocol for interactive content that supports cursor movement, mutation,
  scrolling, and search.

  `NavigableContent` sits above `Minga.Text.Readable` in the abstraction
  stack. `Readable` handles read-only text access (content, line_at,
  line_count, offset_to_position) and is used by Motion and TextObject.
  `NavigableContent` adds the interaction layer: where is the cursor, how
  do we move it, can we edit, how do we scroll and search.

  Content types implement both protocols. File buffers, agent chat
  messages, terminal scrollback, and any future content type each provide
  their own adapter. Vim commands are written once against these two
  protocols and work everywhere.

  ## Coordinate system

  Position is always `{line, col}` where both are zero-indexed. What
  `col` means depends on the adapter: byte offset for Document-backed
  content (matching tree-sitter and the Zig renderer), grapheme index
  for simpler content types. The protocol does not prescribe a column
  semantics; each adapter defines its own.

  ## Read-only content

  Content types that don't support editing (chat messages, terminal
  scrollback) return `false` from `editable?/1`. Calling `replace_range/4`
  on non-editable content returns the content unchanged. Commands check
  `editable?/1` before attempting mutations.

  ## Snapshot model

  Protocol implementations operate on value types (structs), not on
  GenServer pids. For `Buffer.Server`, the caller takes a snapshot
  (`Document.t()` wrapped in a `BufferSnapshot`), runs commands against
  it, then applies the result back. This keeps commands composable and
  testable without running processes.
  """

  alias Minga.Scroll

  @typedoc "A zero-indexed `{line, col}` cursor position."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @doc "Returns the current cursor position."
  @spec cursor(t()) :: position()
  def cursor(content)

  @doc "Moves the cursor to the given position, clamped to content bounds."
  @spec set_cursor(t(), position()) :: t()
  def set_cursor(content, position)

  @doc "Returns true if this content supports editing (insert, delete, replace)."
  @spec editable?(t()) :: boolean()
  def editable?(content)

  @doc """
  Replaces the text in the given range with `text`.

  For editable content, deletes from `start_pos` to `end_pos` and inserts
  `text` at `start_pos`. Pass an empty string to delete without inserting.
  Pass equal positions to insert without deleting.

  For non-editable content, returns the content unchanged.
  """
  @spec replace_range(t(), position(), position(), String.t()) :: t()
  def replace_range(content, start_pos, end_pos, text)

  @doc "Returns the current scroll state."
  @spec scroll(t()) :: Scroll.t()
  def scroll(content)

  @doc "Updates the scroll state."
  @spec set_scroll(t(), Scroll.t()) :: t()
  def set_scroll(content, scroll)

  @doc """
  Searches forward from `from_pos` for `pattern`. Returns the position
  of the first match, or nil if not found.

  Searches from `from_pos` to end of content, then wraps to the
  beginning if no match is found after the starting position.
  """
  @spec search_forward(t(), String.t(), position()) :: position() | nil
  def search_forward(content, pattern, from_pos)

  @doc """
  Searches backward from `from_pos` for `pattern`. Returns the position
  of the first match before the cursor, or nil if not found.

  Searches from `from_pos` backward to the beginning, then wraps to
  the end if no match is found before the starting position.
  """
  @spec search_backward(t(), String.t(), position()) :: position() | nil
  def search_backward(content, pattern, from_pos)
end
