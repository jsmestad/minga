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

  @typedoc "A prefix sequence definition: {key_sequence, command, description}."
  @type prefix_def :: {[Bindings.key()], atom(), String.t()}

  @prefix_sequences [
    # g prefix
    {[{?g, 0}, {?g, 0}], :move_to_document_start, "Go to first line"},
    {[{?g, 0}, {?c, 0}], :enter_comment_operator, "Comment operator"},
    {[{?g, 0}, {?d, 0}], :goto_definition, "Go to definition"},
    {[{?g, 0}, {?j, 0}], :move_logical_down, "Logical line down"},
    {[{?g, 0}, {?k, 0}], :move_logical_up, "Logical line up"},
    {[{?g, 0}, {?0, 0}], :move_to_logical_line_start, "Logical line start"},
    {[{?g, 0}, {?$, 0}], :move_to_logical_line_end, "Logical line end"},
    {[{?g, 0}, {?t, 0}], :tab_next, "Next tab"},
    {[{?g, 0}, {?T, 0}], :tab_prev, "Previous tab"},

    # z prefix (folds)
    {[{?z, 0}, {?a, 0}], :fold_toggle, "Toggle fold"},
    {[{?z, 0}, {?c, 0}], :fold_close, "Close fold"},
    {[{?z, 0}, {?o, 0}], :fold_open, "Open fold"},
    {[{?z, 0}, {?M, 0}], :fold_close_all, "Close all folds"},
    {[{?z, 0}, {?R, 0}], :fold_open_all, "Open all folds"},
    {[{?z, 0}, {?z, 0}], :scroll_center, "Center viewport on cursor"},
    {[{?z, 0}, {?t, 0}], :scroll_cursor_top, "Scroll cursor to top"},
    {[{?z, 0}, {?b, 0}], :scroll_cursor_bottom, "Scroll cursor to bottom"},

    # ] prefix (next)
    {[{?], 0}, {?d, 0}], :next_diagnostic, "Next diagnostic"},
    {[{?], 0}, {?c, 0}], :next_git_hunk, "Next git hunk"},
    {[{?], 0}, {?f, 0}], {:goto_next_textobject, :function}, "Next function"},
    {[{?], 0}, {?t, 0}], {:goto_next_textobject, :class}, "Next class/module"},
    {[{?], 0}, {?a, 0}], {:goto_next_textobject, :parameter}, "Next parameter"},

    # [ prefix (previous)
    {[{?[, 0}, {?d, 0}], :prev_diagnostic, "Previous diagnostic"},
    {[{?[, 0}, {?c, 0}], :prev_git_hunk, "Previous git hunk"},
    {[{?[, 0}, {?f, 0}], {:goto_prev_textobject, :function}, "Previous function"},
    {[{?[, 0}, {?t, 0}], {:goto_prev_textobject, :class}, "Previous class/module"},
    {[{?[, 0}, {?a, 0}], {:goto_prev_textobject, :parameter}, "Previous parameter"}
  ]

  @doc "Returns the compiled prefix trie for normal mode."
  @spec trie() :: Bindings.node_t()
  def trie do
    Enum.reduce(@prefix_sequences, Bindings.new(), fn {keys, command, desc}, trie ->
      Bindings.bind(trie, keys, command, desc)
    end)
  end
end
