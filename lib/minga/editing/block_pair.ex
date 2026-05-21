defmodule Minga.Editing.BlockPair do
  @moduledoc """
  Language-aware block-closing keyword lookup for Insert mode newline handling.

  This module is pure Layer 0 logic. It only inspects language-owned block-pair metadata and the current line text, then returns the closing keyword that should be inserted on the following line.
  """

  alias Minga.Language.BlockPair, as: BlockPairSpec

  @doc """
  Returns the closing keyword for a block-opening line, or `nil` when the line is not a block opener.

  The matcher rejects keywords embedded in longer identifiers and treats Ruby line-head keywords as block openers only when they start the trimmed line. That avoids modifier forms such as `return x if ready`.
  """
  @spec closing_for([BlockPairSpec.t()], String.t()) :: String.t() | nil
  def closing_for(block_pairs, line_text) when is_list(block_pairs) and is_binary(line_text) do
    Enum.find_value(block_pairs, fn %BlockPairSpec{} = pair ->
      if opener_matches?(pair.match, pair.opener, line_text), do: pair.closer, else: nil
    end)
  end

  def closing_for(_block_pairs, _line_text), do: nil

  @spec opener_matches?(BlockPairSpec.match(), String.t(), String.t()) :: boolean()
  defp opener_matches?(:line_head, opener, line_text) do
    trimmed = String.trim(line_text)
    Regex.match?(~r/^#{Regex.escape(opener)}(\b|\s|$)/, trimmed)
  end

  defp opener_matches?(:line_suffix, "fn", line_text) do
    trimmed = String.trim_trailing(line_text)
    Regex.match?(~r/(^|\W)fn\b(.*->)?\s*$/, trimmed)
  end

  defp opener_matches?(:line_suffix, "do", line_text) do
    trimmed = String.trim_trailing(line_text)
    Regex.match?(~r/(^|\W)do\b(\s*\|[^|]*\|)?\s*$/, trimmed)
  end

  defp opener_matches?(:line_suffix, opener, line_text) do
    trimmed = String.trim_trailing(line_text)
    Regex.match?(~r/(^|\W)#{Regex.escape(opener)}\s*$/, trimmed)
  end
end
