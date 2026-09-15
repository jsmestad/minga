defmodule Minga.Buffer.CursorContext do
  @moduledoc """
  Coherent buffer metadata for cursor-local operations.

  Cursor columns use Minga's internal UTF-8 byte offsets. `grapheme_column`
  records the corresponding grapheme offset explicitly so callers never need
  to treat a byte offset as a `String.slice/3` index.
  """

  alias Minga.Buffer.Document

  @enforce_keys [
    :line,
    :byte_column,
    :grapheme_column,
    :line_text,
    :line_prefix,
    :version,
    :file_path,
    :filetype
  ]
  defstruct [
    :line,
    :byte_column,
    :grapheme_column,
    :line_text,
    :line_prefix,
    :version,
    :file_path,
    :filetype
  ]

  @type t :: %__MODULE__{
          line: non_neg_integer(),
          byte_column: non_neg_integer(),
          grapheme_column: non_neg_integer(),
          line_text: String.t(),
          line_prefix: String.t(),
          version: non_neg_integer(),
          file_path: String.t() | nil,
          filetype: atom()
        }

  @doc "Builds a coherent cursor-local snapshot from buffer-owned state."
  @spec new(Document.t(), non_neg_integer(), String.t() | nil, atom()) :: t()
  def new(%Document{} = document, version, file_path, filetype)
      when is_integer(version) and version >= 0 and (is_binary(file_path) or is_nil(file_path)) and
             is_atom(filetype) do
    {line, byte_column} = Document.cursor(document)
    line_text = Document.line_at(document, line) || ""
    line_prefix = binary_part(line_text, 0, byte_column)

    %__MODULE__{
      line: line,
      byte_column: byte_column,
      grapheme_column: String.length(line_prefix),
      line_text: line_text,
      line_prefix: line_prefix,
      version: version,
      file_path: file_path,
      filetype: filetype
    }
  end

  @doc "Returns the internal byte-indexed cursor position."
  @spec position(t()) :: Document.position()
  def position(%__MODULE__{line: line, byte_column: byte_column}), do: {line, byte_column}

  @doc "Returns the text between a same-line byte position and the cursor."
  @spec text_since(t(), Document.position()) :: String.t() | nil
  def text_since(
        %__MODULE__{line: line, byte_column: cursor_column, line_prefix: prefix},
        {line, start_column}
      )
      when start_column >= 0 and start_column <= cursor_column do
    binary_part(prefix, start_column, cursor_column - start_column)
  end

  def text_since(%__MODULE__{}, {_line, _column}), do: nil
end
