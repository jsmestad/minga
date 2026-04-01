defmodule MingaEditor.Indent do
  @moduledoc """
  Computes indentation for new lines.

  Uses a two-step approach:
  1. Copy the previous line's leading whitespace as the baseline indent
  2. Apply a tree-sitter-informed delta: indent after lines ending with
     indent triggers (do, fn, {, [, etc.), dedent on lines starting with
     dedent triggers (end, }, ], etc.)

  The indent triggers are defined per-language. Languages without triggers
  fall back to pure copy-indent.
  """

  alias Minga.Buffer

  @typedoc "A computed indentation result."
  @type indent_result :: %{indent: String.t(), dedent: boolean()}

  @doc """
  Computes the indentation string for a new line inserted after `line_num`.

  Returns the whitespace string that should be inserted after the newline.
  """
  @spec compute_for_newline(pid(), non_neg_integer()) :: String.t()
  def compute_for_newline(buf, line_num) do
    base_indent = leading_whitespace(buf, line_num)
    tab_size = Buffer.get_option(buf, :tab_size) || 2
    indent_with = Buffer.get_option(buf, :indent_with) || :spaces
    unit = indent_unit(indent_with, tab_size)

    filetype = Buffer.filetype(buf)

    case get_line_text(buf, line_num) do
      nil ->
        base_indent

      line_text ->
        trimmed = String.trim_trailing(line_text)

        if should_indent_after?(trimmed, filetype) do
          base_indent <> unit
        else
          base_indent
        end
    end
  end

  @doc """
  Checks if the current line (after cursor) starts with a dedent trigger
  and returns the adjusted indentation.

  Call this after inserting the newline and indent to check if the cursor
  line should be dedented.
  """
  @spec should_dedent_line?(pid(), non_neg_integer()) :: boolean()
  def should_dedent_line?(buf, line_num) do
    case get_line_text(buf, line_num) do
      nil -> false
      text -> dedent_trigger?(String.trim(text), Buffer.filetype(buf))
    end
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

  @doc """
  Removes one level of indentation from the given whitespace string.

  If the whitespace ends with a tab, removes one tab. Otherwise removes
  `tab_size` spaces (or whatever is available).
  """
  @spec remove_one_indent_level(String.t(), pid()) :: String.t()
  def remove_one_indent_level(indent, buf) do
    tab_size = Buffer.get_option(buf, :tab_size) || 2

    if String.ends_with?(indent, "\t") do
      String.slice(indent, 0, String.length(indent) - 1)
    else
      remove_len = min(tab_size, byte_size(indent))
      binary_part(indent, 0, byte_size(indent) - remove_len)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

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

  # ── Indent triggers (per-language) ─────────────────────────────────────────
  #
  # These are simplified heuristics that work well for the common case.
  # The tree-sitter indent query provides the definitive answer, but
  # these patterns give instant feedback without a protocol roundtrip.

  @spec should_indent_after?(String.t(), atom() | String.t()) :: boolean()
  defp should_indent_after?(trimmed, filetype) when filetype in [:elixir, "elixir"] do
    String.ends_with?(trimmed, " do") or
      String.ends_with?(trimmed, "do") or
      String.ends_with?(trimmed, "->") or
      String.ends_with?(trimmed, "fn") or
      String.ends_with?(trimmed, "{") or
      String.ends_with?(trimmed, "[") or
      String.ends_with?(trimmed, "(")
  end

  defp should_indent_after?(trimmed, filetype) when filetype in [:ruby, "ruby"] do
    String.ends_with?(trimmed, " do") or
      String.ends_with?(trimmed, "do") or
      String.ends_with?(trimmed, "{") or
      String.ends_with?(trimmed, "[") or
      String.ends_with?(trimmed, "(") or
      Regex.match?(~r/\b(def|class|module|if|unless|while|until|for|begin|case)\b/, trimmed)
  end

  defp should_indent_after?(trimmed, filetype) when filetype in [:python, "python"] do
    String.ends_with?(trimmed, ":") or
      String.ends_with?(trimmed, "{") or
      String.ends_with?(trimmed, "[") or
      String.ends_with?(trimmed, "(")
  end

  # C-family languages (c, cpp, java, javascript, typescript, go, rust, etc.)
  defp should_indent_after?(trimmed, _filetype) do
    String.ends_with?(trimmed, "{") or
      String.ends_with?(trimmed, "[") or
      String.ends_with?(trimmed, "(")
  end

  @spec dedent_trigger?(String.t(), atom() | String.t()) :: boolean()
  defp dedent_trigger?(trimmed, filetype) when filetype in [:elixir, "elixir"] do
    trimmed == "end" or
      String.starts_with?(trimmed, "end ") or
      trimmed == ")" or trimmed == "]" or trimmed == "}"
  end

  defp dedent_trigger?(trimmed, filetype) when filetype in [:ruby, "ruby"] do
    trimmed == "end" or
      trimmed == ")" or trimmed == "]" or trimmed == "}"
  end

  defp dedent_trigger?(trimmed, filetype) when filetype in [:python, "python"] do
    String.starts_with?(trimmed, "return ") or
      String.starts_with?(trimmed, "pass") or
      String.starts_with?(trimmed, "break") or
      String.starts_with?(trimmed, "continue") or
      trimmed == ")" or trimmed == "]" or trimmed == "}"
  end

  defp dedent_trigger?(trimmed, _filetype) do
    trimmed == "}" or trimmed == ")" or trimmed == "]"
  end
end
