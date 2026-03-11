defprotocol Minga.Text.Readable do
  @moduledoc """
  Protocol for read-only access to text content.

  Any data structure that holds text and can answer positional queries
  can implement this protocol. The vim motion, text-object, and operator
  systems dispatch through `Readable` so they work with any text container:
  gap buffers (`Document`), plain line lists (`TextField`), or future types
  like ropes.

  ## Required callbacks

  | Function             | Purpose                                       |
  |----------------------|-----------------------------------------------|
  | `content/1`          | Full text as a single string                  |
  | `line_at/2`          | Nth line (0-indexed), nil if out of range     |
  | `line_count/1`       | Total number of lines (always >= 1)           |
  | `offset_to_position/2` | Byte offset to `{line, col}` position       |
  """

  @typedoc "A zero-indexed `{line, col}` cursor position."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @doc "Returns the full text content as a single string with newline separators."
  @spec content(t()) :: String.t()
  def content(text)

  @doc "Returns the line at the given 0-based index, or nil if out of range."
  @spec line_at(t(), non_neg_integer()) :: String.t() | nil
  def line_at(text, line_index)

  @doc "Returns the total number of lines. Always >= 1 (empty text has one empty line)."
  @spec line_count(t()) :: pos_integer()
  def line_count(text)

  @doc """
  Converts a byte offset (from the start of content) to a `{line, col}` position.

  Used by word motions that search through the full text content and need
  to convert a match position back to line/col coordinates.
  """
  @spec offset_to_position(t(), non_neg_integer()) :: position()
  def offset_to_position(text, byte_offset)
end
