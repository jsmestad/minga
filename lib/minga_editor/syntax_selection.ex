defmodule MingaEditor.SyntaxSelection do
  @moduledoc """
  Smart selection from the syntax tree, for buffers no language server serves.

  `SPC c v` and `SPC c V` (and their aliases `⌥h` and `⌥l`) expand and shrink the selection by syntax node. A language server answers that with `textDocument/selectionRange`. Without one, this module builds the same chain from tree-sitter: the named nodes around the selection, innermost first, each strictly larger than the last. `MingaEditor.LspActions` stores the chain and walks it exactly as it walks a language server's.

  Ranges use buffer coordinates with an inclusive end, so the end is where the cursor sits in a Visual selection.
  """

  alias Minga.Buffer
  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.Parser.StructuralNavResult

  @typedoc "One selection step: an inclusive range in buffer coordinates."
  @type range :: %{
          start_line: non_neg_integer(),
          start_col: non_neg_integer(),
          end_line: non_neg_integer(),
          end_col: non_neg_integer()
        }

  @typedoc "The current selection as inclusive start and end positions, or the cursor when nothing is selected."
  @type selection :: {Buffer.position(), Buffer.position()}

  # Syntax trees nest far less deeply than this; the bound only stops a runaway walk.
  @max_depth 64

  @doc """
  Returns the syntax ranges that strictly enclose `selection`, innermost first.

  An empty list means no named node encloses the selection, or the buffer has no syntax tree.
  """
  @spec ranges(pid(), selection(), GenServer.server()) :: [range()]
  def ranges(buffer, {{row, col}, _end} = selection, parser) when is_pid(buffer) do
    0..@max_depth
    |> Enum.reduce_while([], fn depth, acc ->
      case ParserManager.request_syntax_ancestor(buffer, row, col, depth, parser) do
        %StructuralNavResult{} = node -> {:cont, [to_range(buffer, node) | acc]}
        nil -> {:halt, acc}
      end
    end)
    |> Enum.reverse()
    |> Enum.dedup()
    |> Enum.filter(&strictly_encloses?(&1, selection))
  end

  @doc "Returns the first named child of the node at the cursor, the step shrink takes when no expansion came before it."
  @spec first_child(pid(), Buffer.position(), GenServer.server()) :: range() | nil
  def first_child(buffer, {row, col}, parser) when is_pid(buffer) do
    case ParserManager.request_structural_nav(buffer, row, col, 1, parser) do
      %StructuralNavResult{} = node -> to_range(buffer, node)
      nil -> nil
    end
  end

  # Tree-sitter ends are exclusive; a Visual selection ends on its last character.
  @spec to_range(pid(), StructuralNavResult.t()) :: range()
  defp to_range(buffer, %StructuralNavResult{} = node) do
    {end_line, end_col} = inclusive_end(buffer, node)

    %{
      start_line: node.start_row,
      start_col: node.start_col,
      end_line: end_line,
      end_col: end_col
    }
  end

  @spec inclusive_end(pid(), StructuralNavResult.t()) :: Buffer.position()
  defp inclusive_end(_buffer, %StructuralNavResult{end_row: row, end_col: col}) when col > 0,
    do: {row, col - 1}

  defp inclusive_end(buffer, %StructuralNavResult{start_row: start_row, end_row: row})
       when row > start_row do
    case Buffer.lines(buffer, row - 1, 1) do
      [line | _] -> {row - 1, max(byte_size(line) - 1, 0)}
      _ -> {row - 1, 0}
    end
  end

  defp inclusive_end(_buffer, %StructuralNavResult{start_row: row, start_col: col}),
    do: {row, col}

  @spec strictly_encloses?(range(), selection()) :: boolean()
  defp strictly_encloses?(range, {sel_start, sel_end}) do
    range_start = {range.start_line, range.start_col}
    range_end = {range.end_line, range.end_col}

    range_start <= sel_start and range_end >= sel_end and
      {range_start, range_end} != {sel_start, sel_end}
  end
end
