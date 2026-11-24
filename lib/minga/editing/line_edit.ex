defmodule Minga.Editing.LineEdit do
  @moduledoc """
  Readline editing for single-line text fields: prompts, the picker query and the `:` command line.

  These keys are text editing, not keymap bindings. The key grammar forbids binding them where you type (`docs/design/keys.md`, rule 4), so each field applies them after its keymap lookup finds nothing, the same way printable keys self-insert.

  | Key | Edit |
  |---|---|
  | `⌃A` | Move to the start of the line |
  | `⌃E` | Move to the end of the line |
  | `⌃H` | Delete the character before the cursor |
  | `⌃W` | Delete the word before the cursor (whitespace-delimited, as in readline) |
  | `⌃U` | Delete from the start of the line to the cursor |
  | `⌃K` | Delete from the cursor to the end of the line |

  Positions are grapheme indexes, as in `MingaEditor.State.Prompt` and `Minga.Mode.CommandState`.
  """

  @ctrl 0x02

  @typedoc "One readline edit."
  @type edit ::
          :line_start
          | :line_end
          | :delete_backward
          | :delete_word_backward
          | :delete_to_start
          | :delete_to_end

  @typedoc "Field text and grapheme cursor."
  @type field :: {String.t(), non_neg_integer()}

  @edits %{
    ?a => :line_start,
    ?e => :line_end,
    ?h => :delete_backward,
    ?w => :delete_word_backward,
    ?u => :delete_to_start,
    ?k => :delete_to_end
  }

  @doc "Returns the readline edit a key performs, or nil when the key is not one."
  @spec edit_for_key({non_neg_integer(), non_neg_integer()}) :: edit() | nil
  def edit_for_key({codepoint, @ctrl}), do: Map.get(@edits, codepoint)
  def edit_for_key({_codepoint, _mods}), do: nil

  @doc "Applies an edit to a field's text and grapheme cursor."
  @spec apply(edit(), String.t(), non_neg_integer()) :: field()
  def apply(edit, text, cursor) when is_binary(text) and is_integer(cursor) and cursor >= 0 do
    graphemes = String.graphemes(text)
    cursor = min(cursor, length(graphemes))
    {before, after_cursor} = Enum.split(graphemes, cursor)
    edit_split(edit, before, after_cursor)
  end

  @spec edit_split(edit(), [String.t()], [String.t()]) :: field()
  defp edit_split(:line_start, before, after_cursor), do: {join(before, after_cursor), 0}

  defp edit_split(:line_end, before, after_cursor),
    do: {join(before, after_cursor), length(before) + length(after_cursor)}

  defp edit_split(:delete_backward, [], after_cursor), do: {join([], after_cursor), 0}

  defp edit_split(:delete_backward, before, after_cursor) do
    kept = Enum.drop(before, -1)
    {join(kept, after_cursor), length(kept)}
  end

  defp edit_split(:delete_word_backward, before, after_cursor) do
    kept =
      before
      |> Enum.reverse()
      |> Enum.drop_while(&whitespace?/1)
      |> Enum.drop_while(&(not whitespace?(&1)))
      |> Enum.reverse()

    {join(kept, after_cursor), length(kept)}
  end

  defp edit_split(:delete_to_start, _before, after_cursor), do: {join([], after_cursor), 0}

  defp edit_split(:delete_to_end, before, _after_cursor),
    do: {join(before, []), length(before)}

  @spec join([String.t()], [String.t()]) :: String.t()
  defp join(before, after_cursor), do: Enum.join(before) <> Enum.join(after_cursor)

  @spec whitespace?(String.t()) :: boolean()
  defp whitespace?(grapheme), do: String.trim(grapheme) == ""
end
