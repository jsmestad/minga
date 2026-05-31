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

  use Minga.Keymap.Scope.Builder,
    name: :agent,
    display_name: "Agent"

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.CUADefaults

  import Minga.Keymap.Sigil

  # Modifier bitmasks
  @ctrl 0x02
  @alt 0x04
  @cmd 0x08

  # Special codepoints
  @enter 13

  # Group specs for each vim state.
  @insert_groups [:ctrl_agent_common, :newline_variants]
  @input_normal_groups [:ctrl_agent_common]
  @cua_groups [:newline_variants, {:cua_navigation, exclude: [:half_page_up, :half_page_down]}]

  # ── Behaviour callbacks ────────────────────────────────────────────────────

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
  def shared_keymap, do: Bindings.new()

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
    |> Bindings.bind(~k(g g), :move_to_document_start, "Go to top")
    |> Bindings.bind(~k(g f), :agent_open_code_block, "Open code block in editor")
    |> Bindings.bind(~k(g a), :agent_apply_code_block, "Apply code block to file")
    |> Bindings.bind(~k(g p), :agent_pin_message, "Pin/unpin message")
    |> Bindings.bind(~k(g d), :goto_definition, "Go to definition")
    # z-prefix: domain fold/collapse commands
    |> Bindings.bind(~k(z a), :agent_toggle_collapse, "Toggle collapse at cursor")
    |> Bindings.bind(~k(z A), :agent_toggle_all_collapse, "Toggle all collapses")
    |> Bindings.bind(~k(z o), :agent_expand_at_cursor, "Expand at cursor")
    |> Bindings.bind(~k(z c), :agent_collapse_at_cursor, "Collapse at cursor")
    |> Bindings.bind(~k(z M), :agent_collapse_all, "Collapse all")
    |> Bindings.bind(~k(z R), :agent_expand_all, "Expand all")
    # ]-prefix: semantic navigation (domain-specific)
    |> Bindings.bind(~k(] m), :agent_next_message, "Next message")
    |> Bindings.bind(~k(] c), :agent_next_code_block, "Next code block/hunk")
    |> Bindings.bind(~k(] t), :agent_next_tool_call, "Next tool call")
    # [-prefix: semantic navigation (domain-specific)
    |> Bindings.bind(~k([ m), :agent_prev_message, "Previous message")
    |> Bindings.bind(~k([ c), :agent_prev_code_block, "Previous code block/hunk")
    |> Bindings.bind(~k([ t), :agent_prev_tool_call, "Previous tool call")
    # Copy (domain: structured copy, not raw yank)
    |> Bindings.bind(~k(y), :agent_copy_code_block, "Copy code block")
    |> Bindings.bind(~k(Y), :agent_copy_message, "Copy full message")
    # Input focus
    |> Bindings.bind(~k(i), :agent_focus_input, "Focus input")
    |> Bindings.bind(~k(a), :agent_focus_input, "Focus input")
    |> Bindings.bind(~k(A), :agent_focus_input, "Focus input (append)")
    |> Bindings.bind(~k(RET), :agent_focus_input, "Focus input")
    # Collapse toggle (magit-style o)
    |> Bindings.bind(~k(o), :agent_toggle_collapse, "Toggle collapse")
    # Panel
    |> Bindings.bind(~k(}), :agent_grow_panel, "Grow chat panel")
    |> Bindings.bind(~k({), :agent_shrink_panel, "Shrink chat panel")
    |> Bindings.bind(~k(=), :agent_reset_panel, "Reset panel split")
    |> Bindings.bind(~k(TAB), :agent_switch_focus, "Switch panel focus")
    # Search: standard vim `/` search works on the *Agent* buffer.
    # Keys `/`, `n`, `N` pass through to the Mode FSM.
    # Session
    |> Bindings.bind(~k(s), :agent_session_switcher, "Session switcher")
    # Help
    |> Bindings.bind(~k(?), :agent_toggle_help, "Toggle help overlay")
    # Return to editor
    |> Bindings.bind(~k(q), :agent_close, "Return to editor")
    |> Bindings.bind(~k(ESC), :agent_dismiss_or_noop, "Dismiss/cancel")
    # Clear
    |> Bindings.bind(~k(C-l), :agent_clear_chat, "Clear chat display")
  end

  # ── Insert mode bindings ───────────────────────────────────────────────────

  @spec insert_trie() :: Bindings.node_t()
  defp insert_trie do
    build_trie(
      groups: @insert_groups,
      then: fn trie ->
        trie
        # ESC switches to input normal mode (vim-style)
        |> Bindings.bind(~k(ESC), :agent_input_to_normal, "Normal mode")
        # Enter submits
        |> Bindings.bind(~k(RET), :agent_submit_or_newline, "Submit prompt")
        # Backspace
        |> Bindings.bind(~k(DEL), :agent_input_backspace, "Delete character")
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
        |> Bindings.bind(~k(C-d), :agent_scroll_half_down, "Scroll down (while typing)")
        |> Bindings.bind(~k(C-u), :agent_scroll_half_up, "Scroll up (while typing)")
      end
    )
  end

  # ── Input normal mode meta keys ──────────────────────────────────────────
  #
  # Vim editing keys (motions, operators, text objects, counts, visual mode)
  # are handled by the standard Mode FSM via dispatch_prompt_via_mode_fsm.
  # This trie only contains meta keys that the Vim module passes through.

  @spec input_normal_trie() :: Bindings.node_t()
  defp input_normal_trie do
    build_trie(
      groups: @input_normal_groups,
      then: fn trie ->
        trie
        # No Escape binding: in normal mode, Escape is a no-op (vim semantics).
        # Use `q` or Ctrl+Q to leave the input field.
        |> Bindings.bind(~k(q), :agent_unfocus_input, "Back to chat nav")
      end
    )
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
         {"SPC a s", "Abort agent turn"},
         {"SPC a S", "Stop agent session"},
         {"SPC a q", "Dequeue to editor"},
         {"SPC a f", "Queue follow-up from input"},
         {"SPC a m", "Pick agent model"},
         {"SPC a c", "Copy file to workspace…"},
         {"SPC a o", "Open remote file"},
         {"SPC a T", "Pick thinking level"}
       ]},
      {"Panel",
       [
         {"Tab", "Switch focus (chat / viewer)"},
         {"{ / }", "Shrink / grow chat panel"},
         {"=", "Reset panel split"}
       ]},
      {"View",
       [
         {"q / Esc", "Return to editor"},
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
         {"Tab", "Switch focus to chat"},
         {"{ / }", "Shrink / grow chat panel"},
         {"=", "Reset panel split"}
       ]},
      {"View",
       [
         {"q / Esc", "Return to editor"},
         {"?", "This help overlay"}
       ]}
    ]
  end

  # ── CUA mode bindings ─────────────────────────────────────────────────────
  # Combined trie for CUA users in the agent panel. The Scoped handler
  # determines whether input is focused and routes accordingly; the trie
  # contains bindings for both states.

  @spec cua_trie() :: Bindings.node_t()
  defp cua_trie do
    build_trie(
      groups: @cua_groups,
      then: fn trie ->
        CUADefaults.navigation_trie()
        |> merge_trie(trie)
        # Enter: focus input if not focused, submit if focused
        |> Bindings.bind(~k(RET), :agent_focus_or_submit, "Focus input / submit")
        |> Bindings.bind(~k(ESC), :agent_dismiss_or_noop, "Dismiss/cancel")
        |> Bindings.bind(~k(TAB), :agent_switch_focus, "Switch panel focus")
        # Cmd chords (GUI) + Ctrl fallbacks (TUI)
        |> Bindings.bind([{?c, @cmd}], :agent_copy_code_block, "Copy code block")
        |> Bindings.bind([{?a, @cmd}], :select_all, "Select all")
        |> Bindings.bind(~k(C-c), :agent_copy_code_block, "Copy code block")
        |> Bindings.bind(~k(C-a), :select_all, "Select all")
        # Input field bindings (used when input focused)
        |> Bindings.bind(~k(DEL), :agent_input_backspace, "Delete character")
        # Arrow up/down in input: history navigation
        |> Bindings.bind([{57_352, 0}], :agent_input_up, "Move up / history prev")
        |> Bindings.bind([{57_353, 0}], :agent_input_down, "Move down / history next")
        |> Bindings.bind([{0xF700, 0}], :agent_input_up, "Move up / history prev")
        |> Bindings.bind([{0xF701, 0}], :agent_input_down, "Move down / history next")
      end
    )
  end

  # Merge two tries together (source wins on conflict).
  @spec merge_trie(Bindings.node_t(), Bindings.node_t()) :: Bindings.node_t()
  defp merge_trie(target, %Bindings.Node{children: children}) do
    Enum.reduce(children, target, fn {key, %Bindings.Node{command: cmd, description: desc}},
                                     acc ->
      if cmd do
        Bindings.bind(acc, [key], cmd, desc || "")
      else
        acc
      end
    end)
  end
end
