defmodule Minga.Buffer.Selection do
  @moduledoc """
  Owns editor selection semantics for document text.

  `Document` stores and mutates the gap buffer. This module decides what a characterwise or linewise selection means, then returns content or a new document from that selection.
  """

  alias Minga.Buffer.{Document, Lines, Position, Span}

  @enforce_keys [:kind, :span, :cursor]
  defstruct [:kind, :span, :cursor]

  @type kind :: :characterwise | :linewise
  @type t :: %__MODULE__{kind: kind(), span: Span.t(), cursor: Document.position()}

  @doc "Builds a characterwise selection between two editor positions."
  @spec characterwise(Document.t(), Document.position(), Document.position()) :: t()
  def characterwise(%Document{} = doc, from_pos, to_pos) do
    {line_starts, text} = Lines.snapshot(doc)
    text_size = byte_size(text)
    from_point = Position.point_in(line_starts, elem(from_pos, 0), elem(from_pos, 1), text_size)
    to_point = Position.point_in(line_starts, elem(to_pos, 0), elem(to_pos, 1), text_size)
    cursor = if from_point <= to_point, do: from_pos, else: to_pos

    %__MODULE__{
      kind: :characterwise,
      span: Span.characterwise(text, from_point, to_point),
      cursor: cursor
    }
  end

  @doc "Builds a linewise selection between two line numbers."
  @spec linewise(Document.t(), non_neg_integer(), non_neg_integer()) :: t()
  def linewise(%Document{} = doc, start_line, end_line) when start_line >= 0 and end_line >= 0 do
    {line_starts, text} = Lines.snapshot(doc)
    text_size = byte_size(text)
    total_lines = tuple_size(line_starts)
    {first_line, last_line} = ordered_lines(start_line, end_line)
    first_line = min(first_line, total_lines - 1)
    last_line = min(last_line, total_lines - 1)
    start_point = Lines.start(line_starts, first_line)
    stop_point = linewise_stop(line_starts, last_line, total_lines, text_size)
    remaining_lines = total_lines - (last_line - first_line + 1)
    cursor_line = min(first_line, max(0, remaining_lines - 1))

    %__MODULE__{
      kind: :linewise,
      span: Span.between(start_point, stop_point),
      cursor: {cursor_line, 0}
    }
  end

  @doc "Returns the selected text."
  @spec contents(Document.t(), t()) :: String.t()
  def contents(%Document{} = doc, %__MODULE__{span: span}) do
    doc |> Document.content() |> Span.slice(span)
  end

  @doc "Returns the joined text for a linewise selection, without a trailing newline."
  @spec line_contents(Document.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def line_contents(%Document{} = doc, start_line, end_line)
      when start_line >= 0 and end_line >= 0 do
    {first_line, last_line} = ordered_lines(start_line, end_line)
    count = last_line - first_line + 1
    doc |> Lines.slice(first_line, count) |> Enum.join("\n")
  end

  @doc "Deletes a selection and places the cursor where that selection began."
  @spec delete(Document.t(), t()) :: Document.t()
  def delete(%Document{} = doc, %__MODULE__{} = selection) do
    text = Document.content(doc)

    new_text =
      text |> Span.delete(selection.span) |> trim_deleted_final_line(selection, byte_size(text))

    new_text |> Document.new() |> Document.move_to(selection.cursor)
  end

  @doc "Clears one line and leaves an empty line behind."
  @spec clear_line(Document.t(), non_neg_integer()) :: {String.t(), Document.t()}
  def clear_line(%Document{} = doc, line) when line >= 0 do
    case Lines.fetch(doc, line) do
      nil ->
        {"", doc}

      "" ->
        {"", Document.move_to(doc, {line, 0})}

      text ->
        {text,
         delete(doc, characterwise(doc, {line, 0}, {line, Position.last_character_on_line(text)}))}
    end
  end

  @spec ordered_lines(non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp ordered_lines(start_line, end_line) do
    if start_line <= end_line, do: {start_line, end_line}, else: {end_line, start_line}
  end

  @spec linewise_stop(Lines.line_starts(), non_neg_integer(), pos_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp linewise_stop(line_starts, line, total_lines, _text_size) when line + 1 < total_lines do
    Lines.start(line_starts, line + 1)
  end

  defp linewise_stop(_line_starts, _line, _total_lines, text_size), do: text_size

  @spec trim_deleted_final_line(String.t(), t(), non_neg_integer()) :: String.t()
  defp trim_deleted_final_line("", %__MODULE__{kind: :linewise}, _original_size), do: ""

  defp trim_deleted_final_line(
         text,
         %__MODULE__{kind: :linewise, span: %Span{stop: stop}},
         original_size
       )
       when stop == original_size do
    if :binary.last(text) == ?\n do
      binary_part(text, 0, byte_size(text) - 1)
    else
      text
    end
  end

  defp trim_deleted_final_line(text, %__MODULE__{}, _original_size), do: text
end
