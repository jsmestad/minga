defmodule MingaEditor.Indent do
  @moduledoc """
  Computes indentation for new lines and reindent commands.

  Tree-sitter is the source of truth when the active buffer has a parser buffer ID. The parser returns an indent level from the language's `indents.scm` query, and this module converts that level into spaces or tabs using the buffer's indentation options. Buffers without a tree-sitter grammar, unavailable parsers, and unsupported parser responses fall back to copy-indent.
  """

  alias Minga.Buffer
  alias Minga.Parser.Manager, as: ParserManager

  @typedoc "Function used to request a parser indent level."
  @type request_indent_fun :: (non_neg_integer(), non_neg_integer() -> integer() | nil)

  @typedoc "Options for tree-sitter indentation."
  @type compute_opt ::
          {:buffer_id, non_neg_integer()}
          | {:fallback, String.t()}
          | {:request_indent, request_indent_fun()}

  @doc """
  Computes the indentation string for an existing line.

  Tree-sitter is queried for `line_num` when a parser buffer ID is available. Otherwise, the result falls back to either the explicit `:fallback` option or copy-indent from the previous line.
  """
  @spec compute_for_line(pid(), non_neg_integer(), [compute_opt()]) :: String.t()
  def compute_for_line(buf, line_num, opts \\ []) do
    fallback = explicit_or_default_fallback(buf, line_num, opts)
    compute_with_tree_sitter(buf, line_num, fallback, opts)
  end

  @doc "Extracts leading whitespace from a line of text."
  @spec extract_leading_ws(String.t()) :: String.t()
  def extract_leading_ws(text) do
    case Regex.run(~r/^(\s*)/, text) do
      [_, ws] -> ws
      _ -> ""
    end
  end

  @doc "Returns the byte offset of the first non-blank character in text."
  @spec first_non_blank_col(String.t()) :: non_neg_integer()
  def first_non_blank_col(text) do
    byte_size(extract_leading_ws(text))
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec compute_with_tree_sitter(pid(), non_neg_integer(), String.t(), [compute_opt()]) ::
          String.t()
  defp compute_with_tree_sitter(buf, line_num, fallback, opts) do
    buffer_id = Keyword.get(opts, :buffer_id, 0)
    request_indent = Keyword.get(opts, :request_indent, &ParserManager.request_indent/2)

    case request_indent_level(buffer_id, line_num, request_indent) do
      level when is_integer(level) and level >= 0 -> whitespace_for_level(buf, level)
      _ -> fallback
    end
  end

  @spec request_indent_level(term(), non_neg_integer(), request_indent_fun()) :: integer() | nil
  defp request_indent_level(buffer_id, line_num, request_indent)
       when is_integer(buffer_id) and buffer_id > 0 do
    request_indent.(buffer_id, line_num)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp request_indent_level(_buffer_id, _line_num, _request_indent), do: nil

  @spec whitespace_for_level(pid(), non_neg_integer()) :: String.t()
  defp whitespace_for_level(buf, level) do
    tab_size = Buffer.get_option(buf, :tab_size) || 2
    indent_with = Buffer.get_option(buf, :indent_with) || :spaces
    unit = indent_unit(indent_with, tab_size)
    String.duplicate(unit, level)
  end

  @spec fallback_for_line(pid(), non_neg_integer()) :: String.t()
  defp fallback_for_line(_buf, 0), do: ""
  defp fallback_for_line(buf, line_num), do: leading_whitespace(buf, line_num - 1)

  @spec explicit_or_default_fallback(pid(), non_neg_integer(), [compute_opt()]) :: String.t()
  defp explicit_or_default_fallback(buf, line_num, opts) do
    case Keyword.fetch(opts, :fallback) do
      {:ok, fallback} -> fallback
      :error -> fallback_for_line(buf, line_num)
    end
  end

  @spec leading_whitespace(pid(), non_neg_integer()) :: String.t()
  defp leading_whitespace(buf, line_num) do
    case get_line_text(buf, line_num) do
      nil -> ""
      text -> extract_leading_ws(text)
    end
  end

  @spec get_line_text(pid(), non_neg_integer()) :: String.t() | nil
  defp get_line_text(buf, line_num) do
    case Buffer.lines(buf, line_num, 1) do
      [text] -> text
      [] -> nil
    end
  end

  @spec indent_unit(:spaces | :tabs, pos_integer()) :: String.t()
  defp indent_unit(:tabs, _tab_size), do: "\t"
  defp indent_unit(:spaces, tab_size), do: String.duplicate(" ", tab_size)
  defp indent_unit(_, tab_size), do: String.duplicate(" ", tab_size)
end
