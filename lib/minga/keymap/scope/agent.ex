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
  def keymap(:input_normal, _context), do: input_normal_trie()
  def keymap(:cua, _context), do: cua_trie()
  def keymap(_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: shared_trie()

  @impl true
  @spec help_groups(atom()) :: [Minga.Keymap.Scope.help_group()]
  def help_groups(:file_viewer), do: viewer_help()
  def help_groups(_focus), do: chat_help()

  @impl true
  @spec included_groups() :: [atom() | {atom(), keyword()}]
  def included_groups do
    [
      :ctrl_agent_common,
      :newline_variants,
      {:cua_navigation, exclude: [:half_page_up, :half_page_down]}
    ]
  end

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
    #
    # Navigation keys (j, k, w, b, e, G, Ctrl-D, Ctrl-U, /, n, N, etc.)
    # are NOT bound here. They pass through to AgentNav, which routes
    # them through the Mode FSM against the *Agent* buffer. This gives
    # chat navigation the full vim grammar for free.
    #
    # Only DOMAIN-SPECIFIC commands live in this trie: collapse, copy,
    # focus, session, panel management.
    #
    # PREFIX RULE: every prefix key claimed by this trie (g, z, ], [)
    # must have ALL reasonable sub-bindings defined. Standard vim commands
    # map to their Mode FSM command atoms. Domain commands map to agent-
    # specific atoms. No sub-binding falls through, because the prefix
    # key was consumed by the trie and the Mode FSM never saw it.
    #
    # g-prefix: domain + vim standard commands
    |> Bindings.bind([{?g, 0}, {?g, 0}], :move_to_document_start, "Go to top")
    |> Bindings.bind([{?g, 0}, {?f, 0}], :agent_open_code_block, "Open code block in editor")
    |> Bindings.bind([{?g, 0}, {?d, 0}], :goto_definition, "Go to definition")
    # z-prefix: domain fold/collapse commands
    |> Bindings.bind([{?z, 0}, {?a, 0}], :agent_toggle_collapse, "Toggle collapse at cursor")
    |> Bindings.bind([{?z, 0}, {?A, 0}], :agent_toggle_all_collapse, "Toggle all collapses")
    |> Bindings.bind([{?z, 0}, {?o, 0}], :agent_expand_at_cursor, "Expand at cursor")
    |> Bindings.bind([{?z, 0}, {?c, 0}], :agent_collapse_at_cursor, "Collapse at cursor")
    |> Bindings.bind([{?z, 0}, {?M, 0}], :agent_collapse_all, "Collapse all")
    |> Bindings.bind([{?z, 0}, {?R, 0}], :agent_expand_all, "Expand all")
    # ]-prefix: semantic navigation (domain-specific)
    |> Bindings.bind([{?], 0}, {?m, 0}], :agent_next_message, "Next message")
    |> Bindings.bind([{?], 0}, {?c, 0}], :agent_next_code_block, "Next code block/hunk")
    |> Bindings.bind([{?], 0}, {?t, 0}], :agent_next_tool_call, "Next tool call")
    # [-prefix: semantic navigation (domain-specific)
    |> Bindings.bind([{?[, 0}, {?m, 0}], :agent_prev_message, "Previous message")
    |> Bindings.bind([{?[, 0}, {?c, 0}], :agent_prev_code_block, "Previous code block/hunk")
    |> Bindings.bind([{?[, 0}, {?t, 0}], :agent_prev_tool_call, "Previous tool call")
    # Copy (domain: structured copy, not raw yank)
    |> Bindings.bind([{?y, 0}], :agent_copy_code_block, "Copy code block")
    |> Bindings.bind([{?Y, 0}], :agent_copy_message, "Copy full message")
    # Input focus
    |> Bindings.bind([{?i, 0}], :agent_focus_input, "Focus input")
    |> Bindings.bind([{?a, 0}], :agent_focus_input, "Focus input")
    |> Bindings.bind([{?A, 0}], :agent_focus_input, "Focus input (append)")
    |> Bindings.bind([{@enter, 0}], :agent_focus_input, "Focus input")
    # Collapse toggle (magit-style o)
    |> Bindings.bind([{?o, 0}], :agent_toggle_collapse, "Toggle collapse")
    # Panel
    |> Bindings.bind([{?}, 0}], :agent_grow_panel, "Grow chat panel")
    |> Bindings.bind([{?{, 0}], :agent_shrink_panel, "Shrink chat panel")
    |> Bindings.bind([{?=, 0}], :agent_reset_panel, "Reset panel split")
    |> Bindings.bind([{@tab, 0}], :agent_switch_focus, "Switch panel focus")
    # Search: standard vim `/` search works on the *Agent* buffer.
    # Keys `/`, `n`, `N` pass through to the Mode FSM.
    # Session
    |> Bindings.bind([{?s, 0}], :agent_session_switcher, "Session switcher")
    # Help
    |> Bindings.bind([{??, 0}], :agent_toggle_help, "Toggle help overlay")
    # Close
    |> Bindings.bind([{?q, 0}], :agent_close, "Close agent split")
    |> Bindings.bind([{@escape, 0}], :agent_dismiss_or_noop, "Dismiss/cancel")
    # Clear
    |> Bindings.bind([{?l, @ctrl}], :agent_clear_chat, "Clear chat display")
  end

  # ── Insert mode bindings ───────────────────────────────────────────────────

  @spec insert_trie() :: Bindings.node_t()
  defp insert_trie do
    Bindings.new()
    # Shared Ctrl shortcuts (Ctrl+C, D, U, L, S, Q) from group
    |> Bindings.merge_group(:ctrl_agent_common)
    # Newline variants (Shift+Enter across all terminal encodings) from group
    |> Bindings.merge_group(:newline_variants)
    # ESC switches to input normal mode (vim-style)
    |> Bindings.bind([{@escape, 0}], :agent_input_to_normal, "Normal mode")
    # Enter submits
    |> Bindings.bind([{@enter, 0}], :agent_submit_or_newline, "Submit prompt")
    # Backspace
    |> Bindings.bind([{@backspace, 0}], :agent_input_backspace, "Delete character")
    # Left/right arrows handled by Vim.handle_key (shared primitive).
    # Up/down arrows handled here: moves cursor OR recalls prompt history.
    |> Bindings.bind([{0xF700, 0}], :agent_input_up, "Move up / history prev")
    |> Bindings.bind([{0xF701, 0}], :agent_input_down, "Move down / history next")
    |> Bindings.bind([{57_352, 0}], :agent_input_up, "Move up / history prev")
    |> Bindings.bind([{57_353, 0}], :agent_input_down, "Move down / history next")
    # Ctrl+Enter queues as follow-up during streaming; submits normally when idle.
    |> Bindings.bind([{@enter, @ctrl}], :agent_queue_follow_up, "Queue as follow-up")
    # Alt+Up dequeues pending messages back into the prompt buffer.
    |> Bindings.bind([{0xF700, @alt}], :agent_dequeue, "Dequeue to editor")
    |> Bindings.bind([{57_352, @alt}], :agent_dequeue, "Dequeue to editor")
    # Scope-specific overrides on top of group bindings:
    # Ctrl+D/U get more specific descriptions in insert context
    |> Bindings.bind([{?d, @ctrl}], :agent_scroll_half_down, "Scroll down (while typing)")
    |> Bindings.bind([{?u, @ctrl}], :agent_scroll_half_up, "Scroll up (while typing)")
  end

  # ── Input normal mode meta keys ──────────────────────────────────────────
  #
  # Vim editing keys (motions, operators, text objects, counts, visual mode)
  # are handled by the standard Mode FSM via dispatch_prompt_via_mode_fsm.
  # This trie only contains meta keys that the Vim module passes through.

  @spec input_normal_trie() :: Bindings.node_t()
  defp input_normal_trie do
    Bindings.new()
    # Shared Ctrl shortcuts from group (Ctrl+C, D, U, L, S, Q)
    |> Bindings.merge_group(:ctrl_agent_common)
    # No Escape binding: in normal mode, Escape is a no-op (vim semantics).
    # Use `q` or Ctrl+Q to leave the input field.
    |> Bindings.bind([{?q, 0}], :agent_unfocus_input, "Back to chat nav")
  end

  # ── Shared bindings (both normal and insert) ───────────────────────────────

  @spec shared_trie() :: Bindings.node_t()
  defp shared_trie do
    # Ctrl+C works the same in both modes
    Bindings.new()
  end

  # ── Help content ───────────────────────────────────────────────────────────

  @spec chat_help() :: [Minga.Keymap.Scope.help_group()]
  defp chat_help do
    [
      {"Navigation",
       [
         {"j / k", "Scroll down / up"},
         {"Ctrl-d / Ctrl-u", "Half page down / up"},
         {"gg / G", "Scroll to top / bottom"},
         {"/", "Search buffer (vim standard)"},
         {"n / N", "Next / prev search result"}
       ]},
      {"Fold / Collapse",
       [
         {"o / za", "Toggle collapse at cursor"},
         {"zA", "Toggle all collapses"},
         {"zM", "Collapse all"},
         {"zR", "Expand all"}
       ]},
      {"Jump",
       [
         {"]m / [m", "Next / prev message"},
         {"]c / [c", "Next / prev code block"},
         {"]t / [t", "Next / prev tool call"}
       ]},
      {"Copy",
       [
         {"y", "Copy code block at cursor"},
         {"Y", "Copy full message at cursor"}
       ]},
      {"Input",
       [
         {"i / a / Enter", "Focus chat input"},
         {"Shift+Enter", "Insert newline in input"},
         {"Up / Down", "History / cursor in input"}
       ]},
      {"Session",
       [
         {"Ctrl-c", "Abort + restore queued (streaming) / normal mode (idle)"},
         {"Ctrl+Enter", "Queue as follow-up (or submit if idle)"},
         {"Alt+Up", "Dequeue messages back to editor"},
         {"Ctrl-l", "Clear display"},
         {"s", "Session switcher"},
         {"SPC a n", "New session"},
         {"SPC a s", "Stop agent"},
         {"SPC a q", "Dequeue to editor"},
         {"SPC a f", "Queue follow-up from input"},
         {"SPC a m", "Pick model"},
         {"SPC a T", "Cycle thinking level"}
       ]},
      {"Panel",
       [
         {"Tab", "Switch focus (chat / viewer)"},
         {"{ / }", "Shrink / grow chat panel"},
         {"=", "Reset panel split"}
       ]},
      {"View",
       [
         {"q", "Close agent split"},
         {"?", "This help overlay"}
       ]}
    ]
  end

  @spec viewer_help() :: [Minga.Keymap.Scope.help_group()]
  defp viewer_help do
    [
      {"Navigation",
       [
         {"j / k", "Scroll down / up"},
         {"Ctrl-d / Ctrl-u", "Half page down / up"},
         {"gg / G", "Scroll to top / bottom"}
       ]},
      {"Session",
       [
         {"Ctrl-c", "Abort agent"}
       ]},
      {"Panel",
       [
         {"Tab / Escape", "Switch focus to chat"},
         {"{ / }", "Shrink / grow chat panel"},
         {"=", "Reset panel split"}
       ]},
      {"View",
       [
         {"q", "Close agent split"},
         {"?", "This help overlay"}
       ]}
    ]
  end

  # ── CUA mode bindings ─────────────────────────────────────────────────────
  # Combined trie for CUA users in the agent panel. The Scoped handler
  # determines whether input is focused and routes accordingly; the trie
  # contains bindings for both states.

  alias Minga.Keymap.CUADefaults

  @cmd 0x08

  @spec cua_trie() :: Bindings.node_t()
  defp cua_trie do
    CUADefaults.navigation_trie()
    # Enter: focus input if not focused, submit if focused
    |> Bindings.bind([{@enter, 0}], :agent_focus_or_submit, "Focus input / submit")
    |> Bindings.bind([{@escape, 0}], :agent_dismiss_or_noop, "Dismiss/cancel")
    |> Bindings.bind([{@tab, 0}], :agent_switch_focus, "Switch panel focus")
    # Cmd chords (GUI) + Ctrl fallbacks (TUI)
    |> Bindings.bind([{?c, @cmd}], :agent_copy_code_block, "Copy code block")
    |> Bindings.bind([{?a, @cmd}], :select_all, "Select all")
    |> Bindings.bind([{?c, @ctrl}], :agent_copy_code_block, "Copy code block")
    |> Bindings.bind([{?a, @ctrl}], :select_all, "Select all")
    # Input field bindings (used when input focused)
    |> Bindings.bind([{@backspace, 0}], :agent_input_backspace, "Delete character")
    |> Bindings.bind([{@enter, @shift}], :agent_insert_newline, "Insert newline")
    |> Bindings.bind([{?j, @ctrl}], :agent_insert_newline, "Insert newline")
    |> Bindings.bind([{0x0A, 0}], :agent_insert_newline, "Insert newline")
    |> Bindings.bind([{@enter, @alt}], :agent_insert_newline, "Insert newline")
    # Arrow up/down in input: history navigation
    |> Bindings.bind([{57_352, 0}], :agent_input_up, "Move up / history prev")
    |> Bindings.bind([{57_353, 0}], :agent_input_down, "Move down / history next")
    |> Bindings.bind([{0xF700, 0}], :agent_input_up, "Move up / history prev")
    |> Bindings.bind([{0xF701, 0}], :agent_input_down, "Move down / history next")
  end
end
