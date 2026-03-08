defmodule Minga.Keymap.Scope.Agent do
  @moduledoc """
  Keymap scope for the full-screen agentic view.

  Provides vim-like navigation, fold/collapse, copy, search, and panel
  management bindings. In normal mode, keys like `j`/`k` scroll the chat,
  `y`/`Y` copy content, and prefix sequences (`z`, `g`, `]`, `[`) provide
  fold, go-to, and bracket navigation.

  In insert mode (input field focused), printable characters go to the input
  field. Ctrl+C submits or aborts, ESC returns to normal mode.

  All bindings are declared as trie data and resolved through the scope
  system. Context-dependent behavior (e.g., `y` copies a code block normally
  but accepts a diff hunk during review) is handled by guards on command
  functions, not separate dispatch paths.
  """

  @behaviour Minga.Keymap.Scope

  alias Minga.Keymap.Bindings

  # Modifier bitmasks
  @ctrl 0x02
  @shift 0x01
  @alt 0x04

  # Special codepoints
  @tab 9
  @enter 13
  @escape 27
  @backspace 127

  # ── Behaviour callbacks ────────────────────────────────────────────────────

  @impl true
  @spec name() :: :agent
  def name, do: :agent

  @impl true
  @spec display_name() :: String.t()
  def display_name, do: "Agent"

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(:normal, _context), do: normal_trie()
  def keymap(:insert, _context), do: insert_trie()
  def keymap(_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: shared_trie()

  @impl true
  @spec on_enter(term()) :: term()
  def on_enter(state), do: state

  @impl true
  @spec on_exit(term()) :: term()
  def on_exit(state), do: state

  # ── Normal mode bindings ───────────────────────────────────────────────────

  @spec normal_trie() :: Bindings.node_t()
  defp normal_trie do
    Bindings.new()
    # Navigation
    |> Bindings.bind([{?j, 0}], :agent_scroll_down, "Scroll down")
    |> Bindings.bind([{?k, 0}], :agent_scroll_up, "Scroll up")
    |> Bindings.bind([{?d, @ctrl}], :agent_scroll_half_down, "Scroll half page down")
    |> Bindings.bind([{?u, @ctrl}], :agent_scroll_half_up, "Scroll half page up")
    |> Bindings.bind([{?G, 0}], :agent_scroll_bottom, "Scroll to bottom")
    # g-prefix
    |> Bindings.bind([{?g, 0}, {?g, 0}], :agent_scroll_top, "Scroll to top")
    |> Bindings.bind([{?g, 0}, {?f, 0}], :agent_open_code_block, "Open code block in editor")
    # z-prefix (fold/collapse)
    |> Bindings.bind([{?z, 0}, {?a, 0}], :agent_toggle_collapse, "Toggle collapse at cursor")
    |> Bindings.bind([{?z, 0}, {?A, 0}], :agent_toggle_all_collapse, "Toggle all collapses")
    |> Bindings.bind([{?z, 0}, {?o, 0}], :agent_expand_at_cursor, "Expand at cursor")
    |> Bindings.bind([{?z, 0}, {?c, 0}], :agent_collapse_at_cursor, "Collapse at cursor")
    |> Bindings.bind([{?z, 0}, {?M, 0}], :agent_collapse_all, "Collapse all")
    |> Bindings.bind([{?z, 0}, {?R, 0}], :agent_expand_all, "Expand all")
    # ]-prefix (next item)
    |> Bindings.bind([{?], 0}, {?m, 0}], :agent_next_message, "Next message")
    |> Bindings.bind([{?], 0}, {?c, 0}], :agent_next_code_block, "Next code block/hunk")
    |> Bindings.bind([{?], 0}, {?t, 0}], :agent_next_tool_call, "Next tool call")
    # [-prefix (prev item)
    |> Bindings.bind([{?[, 0}, {?m, 0}], :agent_prev_message, "Previous message")
    |> Bindings.bind([{?[, 0}, {?c, 0}], :agent_prev_code_block, "Previous code block/hunk")
    |> Bindings.bind([{?[, 0}, {?t, 0}], :agent_prev_tool_call, "Previous tool call")
    # Copy
    |> Bindings.bind([{?y, 0}], :agent_copy_code_block, "Copy code block")
    |> Bindings.bind([{?Y, 0}], :agent_copy_message, "Copy full message")
    # Input focus
    |> Bindings.bind([{?i, 0}], :agent_focus_input, "Focus input")
    |> Bindings.bind([{?a, 0}], :agent_focus_input, "Focus input")
    |> Bindings.bind([{@enter, 0}], :agent_focus_input, "Focus input")
    # Collapse toggle (magit-style o)
    |> Bindings.bind([{?o, 0}], :agent_toggle_collapse, "Toggle collapse")
    # Panel
    |> Bindings.bind([{?}, 0}], :agent_grow_panel, "Grow chat panel")
    |> Bindings.bind([{?{, 0}], :agent_shrink_panel, "Shrink chat panel")
    |> Bindings.bind([{?=, 0}], :agent_reset_panel, "Reset panel split")
    |> Bindings.bind([{@tab, 0}], :agent_switch_focus, "Switch panel focus")
    # Search
    |> Bindings.bind([{?/, 0}], :agent_start_search, "Search")
    |> Bindings.bind([{?n, 0}], :agent_next_search_match, "Next search match")
    |> Bindings.bind([{?N, 0}], :agent_prev_search_match, "Previous search match")
    # Session
    |> Bindings.bind([{?s, 0}], :agent_session_switcher, "Session switcher")
    # Help
    |> Bindings.bind([{??, 0}], :agent_toggle_help, "Toggle help overlay")
    # Close
    |> Bindings.bind([{?q, 0}], :agent_close, "Close agentic view")
    |> Bindings.bind([{@escape, 0}], :agent_dismiss_or_noop, "Dismiss/cancel")
    # Clear
    |> Bindings.bind([{?l, @ctrl}], :agent_clear_chat, "Clear chat display")
  end

  # ── Insert mode bindings ───────────────────────────────────────────────────

  @spec insert_trie() :: Bindings.node_t()
  defp insert_trie do
    Bindings.new()
    # ESC exits insert mode (unfocus input)
    |> Bindings.bind([{@escape, 0}], :agent_unfocus_input, "Unfocus input")
    # Ctrl+Q unfocus + quit
    |> Bindings.bind([{?q, @ctrl}], :agent_unfocus_and_quit, "Unfocus input and quit")
    # Enter submits (plain), Shift+Enter or Alt+Enter inserts newline
    |> Bindings.bind([{@enter, 0}], :agent_submit_or_newline, "Submit prompt")
    |> Bindings.bind([{@enter, @shift}], :agent_insert_newline, "Insert newline")
    |> Bindings.bind([{@enter, @alt}], :agent_insert_newline, "Insert newline")
    # Backspace
    |> Bindings.bind([{@backspace, 0}], :agent_input_backspace, "Delete character")
    # Navigation in input
    |> Bindings.bind([{0xF700, 0}], :agent_input_up, "Move up / history prev")
    |> Bindings.bind([{0xF701, 0}], :agent_input_down, "Move down / history next")
    # Ctrl modifiers
    |> Bindings.bind([{?c, @ctrl}], :agent_submit_or_abort, "Submit or abort")
    |> Bindings.bind([{?d, @ctrl}], :agent_scroll_half_down, "Scroll down (while typing)")
    |> Bindings.bind([{?u, @ctrl}], :agent_scroll_half_up, "Scroll up (while typing)")
    |> Bindings.bind([{?l, @ctrl}], :agent_clear_chat, "Clear chat display")
    |> Bindings.bind([{?s, @ctrl}], :agent_save_buffer, "Save buffer")
  end

  # ── Shared bindings (both normal and insert) ───────────────────────────────

  @spec shared_trie() :: Bindings.node_t()
  defp shared_trie do
    # Ctrl+C works the same in both modes
    Bindings.new()
  end
end
