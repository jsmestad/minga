defmodule Minga.Keymap.NormalPrefixes do
  @moduledoc """
  Declarative prefix key sequences for normal mode.

  Defines all multi-key sequences that use `g`, `z`, `[`, `]` as prefix
  keys. These are built into a `Bindings` trie at compile time so normal
  mode can walk the trie instead of using fragile `pending_*` boolean flags.

  Commands that need non-standard results (e.g., `gc` transitions to
  operator-pending mode) use tagged atoms that the normal mode handler
  interprets.
  """

  alias Minga.Keymap.Bindings

  import Minga.Keymap.Sigil

  @typedoc "A prefix sequence definition: {key_sequence, command, description}."
  @type prefix_def :: {[Bindings.key()], atom() | tuple(), String.t()}

  @prefix_sequences [
    # g prefix
    {~k(g g), :move_to_document_start, "Go to first line"},
    {~k(g c), :enter_comment_operator, "Comment operator"},
    {~k(g d), :goto_definition, "Go to definition"},
    {~k(g r), :find_references, "Find references"},
    {~k(g .), :code_action, "Code actions"},
    {~k(g y), :goto_type_definition, "Go to type definition"},
    {~k(g i), :goto_implementation, "Go to implementation"},
    {~k(g j), :move_logical_down, "Logical line down"},
    {~k(g k), :move_logical_up, "Logical line up"},
    {~k(g 0), :move_to_logical_line_start, "Logical line start"},
    {~k(g $), :move_to_logical_line_end, "Logical line end"},
    {~k(g t), :tab_next, "Next tab"},
    {~k(g T), :tab_prev, "Previous tab"},

    # z prefix (folds)
    {~k(z a), :fold_toggle, "Toggle fold"},
    {~k(z c), :fold_close, "Close fold"},
    {~k(z o), :fold_open, "Open fold"},
    {~k(z C), :fold_close_recursive, "Close folds recursively"},
    {~k(z O), :fold_open_recursive, "Open folds recursively"},
    {~k(z M), :fold_close_all, "Close all folds"},
    {~k(z R), :fold_open_all, "Open all folds"},
    {~k(z z), :scroll_center, "Center viewport on cursor"},
    {~k(z t), :scroll_cursor_top, "Scroll cursor to top"},
    {~k(z b), :scroll_cursor_bottom, "Scroll cursor to bottom"},

    # ] prefix (next)
    {~k(] d), :next_diagnostic, "Next diagnostic"},
    {~k(] c), :next_git_hunk, "Next git hunk"},
    {~k(] x), :next_merge_conflict, "Next merge conflict"},
    {~k(] f), {:goto_next_textobject, :function}, "Next function"},
    {~k(] t), {:goto_next_textobject, :class}, "Next class/module"},
    {~k(] a), {:goto_next_textobject, :parameter}, "Next parameter"},

    # [ prefix (previous)
    {~k([ d), :prev_diagnostic, "Previous diagnostic"},
    {~k([ c), :prev_git_hunk, "Previous git hunk"},
    {~k([ x), :prev_merge_conflict, "Previous merge conflict"},
    {~k([ f), {:goto_prev_textobject, :function}, "Previous function"},
    {~k([ t), {:goto_prev_textobject, :class}, "Previous class/module"},
    {~k([ a), {:goto_prev_textobject, :parameter}, "Previous parameter"}
  ]

  @doc "Returns the compiled prefix trie for normal mode."
  @spec trie() :: Bindings.node_t()
  def trie do
    Enum.reduce(@prefix_sequences, Bindings.new(), fn {keys, command, desc}, trie ->
      Bindings.bind(trie, keys, command, desc)
    end)
  end
end
