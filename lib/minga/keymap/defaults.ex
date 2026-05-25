defmodule Minga.Keymap.Defaults do
  @moduledoc """
  Doom Emacs-style default leader keybindings for Minga.

  All bindings are rooted at the **SPC** (space) leader key in Normal mode.
  Group prefix nodes are labelled with `+group` descriptions so that the
  which-key popup can display them meaningfully.

  ## Key groups

  | Prefix    | Group       |
  |-----------|-------------|
  | `SPC f`   | +file       |
  | `SPC b`   | +buffer     |
  | `SPC w`   | +window     |
  | `SPC s`   | +search     |
  | `SPC c`   | +code       |
  | `SPC g`   | +git        |
  | `SPC o`   | +open       |
  | `SPC a`   | +ai         |
  | `SPC t`   | +toggle     |
  | `SPC p`   | +project    |
  | `SPC q`   | +quit       |
  | `SPC h`   | +help       |
  | `SPC m`   | +filetype   |
  """

  alias Minga.Keymap.Bindings

  import Minga.Keymap.Sigil

  # ---------------------------------------------------------------------------
  # Leaf bindings: {key_sequence, command_atom, description}
  # Key sequences are relative to the leader key (SPC is implicit).
  # ---------------------------------------------------------------------------

  @leader_bindings [
    # ── Command palette ──────────────────────────────────────────────────────
    {~k(:), :command_palette, "Execute command"},

    # ── Search ─────────────────────────────────────────────────────────────────
    {~k(s p), :search_project, "Search project"},
    {~k(s s), :search_buffer, "Search in buffer"},
    {~k(s t), :search_todos, "Search TODOs"},
    {~k(s r), :search_and_replace, "Search and replace"},
    {~k(s j), :document_symbols, "Search document symbols"},
    {~k(s w), :workspace_symbols, "Search workspace symbols"},
    {~k(/), :search_project, "Search project"},

    # ── File ──────────────────────────────────────────────────────────────────
    {~k(f f), :find_file, "Find file"},
    {~k(f F), :find_file_other_window, "Find file other window"},
    {~k(f s), :save, "Save file"},
    {~k(f p), :open_config, "Open config file"},
    {~k(f d), :dired_open, "Open directory (Dired)"},

    # ── Buffer ────────────────────────────────────────────────────────────────
    {~k(b b), :buffer_list, "Switch buffer"},
    {~k(b B), :buffer_list_all, "Switch buffer (all)"},
    {~k(b n), :buffer_next, "Next buffer"},
    {~k(b p), :buffer_prev, "Previous buffer"},
    {~k(b d), :kill_buffer, "Kill buffer"},
    {~k(b m), :view_messages, "View messages"},
    {~k(b W), :view_warnings, "View warnings"},
    {~k(b N), :new_buffer, "New buffer"},
    {~k(b l), :set_language, "Set language"},
    {~k(b P), :pin_tab, "Pin/unpin tab"},
    {~k(b <), :move_tab_left, "Move tab left"},
    {~k(b >), :move_tab_right, "Move tab right"},

    # ── Window ────────────────────────────────────────────────────────────────
    {~k(w h), :window_left, "Window left"},
    {~k(w j), :window_down, "Window down"},
    {~k(w k), :window_up, "Window up"},
    {~k(w l), :window_right, "Window right"},
    {~k(w v), :split_vertical, "Vertical split"},
    {~k(w s), :split_horizontal, "Horizontal split"},
    {~k(w d), :window_close, "Close window"},

    # ── Quit ──────────────────────────────────────────────────────────────────
    {~k(q q), :quit_all, "Quit editor"},

    # ── Help ──────────────────────────────────────────────────────────────────
    {~k(h b), :describe_bindings, "Describe bindings"},
    {~k(h c), :describe_command, "Describe command"},
    {~k(h f), :describe_function, "Describe function"},
    {~k(h k), :describe_key, "Describe key"},
    {~k(h l), :describe_lossage, "Show keystroke history"},
    {~k(h v), :describe_option, "Describe option"},
    {~k(h r), :reload_config, "Reload config"},
    {~k(h t), :theme_picker, "Pick theme"},
    {~k(h e l), :extension_list, "List extensions"},
    {~k(h e u), :extension_update_all, "Update all extensions"},
    {~k(h e U), :extension_update, "Update extension"},
    {~k(h T), :tutor, "Interactive tutorial"},

    # ── Code ────────────────────────────────────────────────────────────────────
    {~k(c a), :code_action, "Code actions"},
    {~k(c d), :diagnostics_list, "List diagnostics"},
    {~k(c D), :find_references, "Find references"},
    {~k(c f), :format_buffer, "Format buffer"},
    {~k(c g), :goto_definition, "Go to definition"},
    {~k(c i), :goto_implementation, "Go to implementation"},
    {~k(c j), :document_symbols, "Document symbols"},
    {~k(c k), :hover, "Hover documentation"},
    {~k(c r), :rename_symbol, "Rename symbol"},
    {~k(c t), :goto_type_definition, "Go to type definition"},
    {~k(c h), :call_hierarchy, "Call hierarchy (incoming)"},
    {~k(c H), :call_hierarchy_outgoing, "Call hierarchy (outgoing)"},
    {~k(c v), :selection_expand, "Smart selection expand"},
    {~k(c V), :selection_shrink, "Smart selection shrink"},
    {~k(c l i), :lsp_info, "LSP info"},
    {~k(c l r), :lsp_restart, "Restart LSP"},
    {~k(c l s), :lsp_stop, "Stop LSP"},
    {~k(c l S), :lsp_start, "Start LSP"},
    {~k(c l I), :tool_manage, "Manage tools"},

    # ── Project ────────────────────────────────────────────────────────────────
    {~k(p f), :project_find_file, "Find file in project"},
    {~k(p p), :project_switch, "Switch project"},
    {~k(p i), :project_invalidate, "Invalidate project cache"},
    {~k(p a), :project_add, "Add known project"},
    {~k(p d), :project_remove, "Remove known project"},
    {~k(p R), :project_recent_files, "Recent files in project"},

    # ── Open ──────────────────────────────────────────────────────────────────
    {~k(o b), :toggle_beam_observatory, "BEAM observatory"},
    {~k(o p), :toggle_file_tree, "Toggle file tree"},
    {~k(o r), :tree_reveal_active, "Reveal file in tree"},

    # ── AI agent ─────────────────────────────────────────────────────────────
    {~k(a a), :toggle_agentic_view, "Toggle agent split"},
    {~k(a t), :toggle_agentic_view, "Toggle agent split"},
    {~k(a v), :toggle_agent_split, "Toggle agent split pane"},
    {~k(a s), :agent_abort, "Abort agent turn"},
    {~k(a S), :agent_stop_session, "Stop agent session"},
    {~k(a n), :agent_new_session, "New agent session"},
    {~k(a ?), :inline_ask, "Ask about line or selection"},
    {~k(a e), :inline_edit, "Rewrite selection inline"},
    {~k(a m), :agent_pick_model, "Pick agent model"},
    {~k(a c), :workspace_copy_file, "Copy file to workspace…"},
    {~k(a M), :agent_cycle_model, "Cycle agent model"},
    {~k(a h), :agent_session_history, "Resume session"},
    {~k(a r), :workspace_pending_reviews, "Pending reviews"},
    {~k(a o), :remote_find_file, "Open remote file"},
    {~k(a T), :agent_pick_thinking, "Pick thinking level"},
    {~k(a z), :agent_summarize, "Summarize session to artifact"},
    {~k(a q), :agent_dequeue, "Dequeue queued messages to editor"},
    {~k(a f), :agent_queue_follow_up, "Queue current input as follow-up"},
    {~k(a u), :undo_agent_session, "Undo all agent edits"},

    # ── Tab ──────────────────────────────────────────────────────────────────
    {~k(TAB n), :tab_next, "Next tab"},
    {~k(TAB p), :tab_prev, "Previous tab"},
    {~k(TAB d), :kill_buffer, "Close tab"},
    {~k(TAB a), :cycle_agent_tabs, "Next agent tab"},

    # ── Workspace (SPC TAB prefix, shared with tab) ──────────────────────────
    {~k(TAB TAB), :workspace_toggle, "Toggle workspace"},
    {~k(TAB N), :workspace_next, "Next workspace"},
    {~k(TAB P), :workspace_prev, "Previous workspace"},
    {~k(TAB A), :workspace_next_agent, "Next workspace"},
    {~k(TAB m), :manual_workspace, "Manual workspace"},
    {~k(TAB l), :workspace_list, "Workspace picker"},
    {~k(TAB r), :workspace_rename, "Rename workspace"},
    {~k(TAB i), :workspace_set_icon, "Set workspace icon"},
    {~k(TAB D), :workspace_close, "Close workspace"},

    # ── Direct tab switching (SPC 1..9) ──────────────────────────────────────
    {~k(1), :tab_goto_1, "Tab 1"},
    {~k(2), :tab_goto_2, "Tab 2"},
    {~k(3), :tab_goto_3, "Tab 3"},
    {~k(4), :tab_goto_4, "Tab 4"},
    {~k(5), :tab_goto_5, "Tab 5"},
    {~k(6), :tab_goto_6, "Tab 6"},
    {~k(7), :tab_goto_7, "Tab 7"},
    {~k(8), :tab_goto_8, "Tab 8"},
    {~k(9), :tab_goto_9, "Tab 9"},

    # ── Toggle ────────────────────────────────────────────────────────────────
    {~k(t l), :cycle_line_numbers, "Toggle line numbers"},
    {~k(t p), :toggle_bottom_panel, "Toggle bottom panel"},
    {~k(t i), :toggle_invisible, "Toggle invisible chars"},
    {~k(t w), :toggle_wrap, "Toggle word wrap"},
    {~k(t b), :toggle_board, "Toggle The Board"}
  ]

  # Group prefix descriptions shown in which-key at the SPC level.
  @group_prefixes [
    {~k(TAB), "+tab"},
    {~k(s), "+search"},
    {~k(f), "+file"},
    {~k(b), "+buffer"},
    {~k(p), "+project"},
    {~k(c), "+code"},
    {~k(c l), "+LSP"},
    {~k(g), "+git"},
    {~k(g c), "+commit"},
    {~k(g x), "+conflict"},
    {~k(g z), "+stash"},
    {~k(w), "+window"},
    {~k(q), "+quit"},
    {~k(h), "+help"},
    {~k(h e), "+extensions"},
    {~k(o), "+open"},
    {~k(a), "+ai"},
    {~k(t), "+toggle"},
    {~k(m), "+filetype"}
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns a trie whose root is the SPC leader key's subtrie.

  The returned node can be passed directly to `Minga.Keymap.Bindings.lookup/2` for
  subsequent keys in the leader sequence.
  """
  @spec leader_trie() :: Bindings.node_t()
  def leader_trie do
    trie_with_bindings =
      Enum.reduce(@leader_bindings, Bindings.new(), fn {keys, command, description}, trie ->
        Bindings.bind(trie, keys, command, description)
      end)

    Enum.reduce(@group_prefixes, trie_with_bindings, fn {keys, description}, trie ->
      Bindings.bind_prefix(trie, keys, description)
    end)
  end

  @doc """
  Returns the leader key as a `t:Minga.Keymap.Bindings.key/0` tuple (SPC = `{32, 0}`).
  """
  @spec leader_key() :: Bindings.key()
  def leader_key, do: ~K(SPC)

  @doc """
  Returns all leader bindings as a flat list of `{key_sequence, command, description}` tuples.
  """
  @spec all_bindings() :: [{[Bindings.key()], atom(), String.t()}]
  def all_bindings, do: @leader_bindings

  @doc """
  Returns leader group prefixes as `{key_sequence, label}` tuples.
  """
  @spec group_prefixes() :: [{[Bindings.key()], String.t()}]
  def group_prefixes, do: @group_prefixes

  # filetype_bindings/0 is defined below with all SPC m bindings

  @doc """
  Returns a map of Normal mode key bindings: `{codepoint, modifiers} => {command, description}`.

  These are the hardcoded bindings from `Minga.Mode.Normal.handle_key/2`,
  maintained as a static data structure for introspection (describe-key).
  """
  @spec normal_bindings() :: %{Bindings.key() => {atom(), String.t()}}
  def normal_bindings do
    %{
      # ── Movement ──────────────────────────────────────────────────────────
      ~K(h) => {:move_left, "Move cursor left"},
      ~K(j) => {:move_down, "Move cursor down"},
      ~K(k) => {:move_up, "Move cursor up"},
      ~K(l) => {:move_right, "Move cursor right"},
      ~K(M-h) => {:nav_parent, "Move to parent AST node"},
      ~K(M-l) => {:nav_first_child, "Move to first child AST node"},
      ~K(M-j) => {:nav_next_sibling, "Move to next sibling AST node"},
      ~K(M-k) => {:nav_prev_sibling, "Move to previous sibling AST node"},
      ~K(0) => {:move_to_line_start, "Move to line start"},
      ~K($) => {:move_to_line_end, "Move to line end"},
      ~K(^) => {:move_to_first_non_blank, "First non-blank character"},
      ~K(G) => {:move_to_document_end, "Go to end of document"},
      ~K(w) => {:word_forward, "Word forward"},
      ~K(b) => {:word_backward, "Word backward"},
      ~K(e) => {:word_end, "Word end"},
      ~K(W) => {:word_forward_big, "WORD forward"},
      ~K(B) => {:word_backward_big, "WORD backward"},
      ~K(E) => {:word_end_big, "WORD end"},
      ~K(%) => {:match_bracket, "Match bracket"},
      ~K({) => {:paragraph_backward, "Paragraph backward"},
      ~K(}) => {:paragraph_forward, "Paragraph forward"},
      ~K(H) => {:move_to_screen_top, "Screen top"},
      ~K(M) => {:move_to_screen_middle, "Screen middle"},
      ~K(L) => {:move_to_screen_bottom, "Screen bottom"},
      ~K(+) => {:next_line_first_non_blank, "Next line first non-blank"},
      ~K(-) => {:prev_line_first_non_blank, "Previous line first non-blank"},
      # ── Find char ─────────────────────────────────────────────────────────
      ~K(f) => {:pending_find_forward, "Find char forward (f{char})"},
      ~K(F) => {:pending_find_backward, "Find char backward (F{char})"},
      ~K(t) => {:pending_till_forward, "Till char forward (t{char})"},
      ~K(T) => {:pending_till_backward, "Till char backward (T{char})"},
      ~K(;) => {:repeat_find_char, "Repeat last find char"},
      ~K(,) => {:repeat_find_char_reverse, "Repeat last find char (reverse)"},
      # ── Scrolling ─────────────────────────────────────────────────────────
      ~K(C-d) => {:half_page_down, "Half page down"},
      ~K(C-u) => {:half_page_up, "Half page up"},
      ~K(C-f) => {:page_down, "Page down"},
      ~K(C-b) => {:page_up, "Page up"},
      # ── Mode transitions ──────────────────────────────────────────────────
      ~K(i) => {:enter_insert, "Insert before cursor"},
      ~K(a) => {:enter_insert_after, "Insert after cursor"},
      ~K(A) => {:enter_insert_end_of_line, "Insert at end of line"},
      ~K(I) => {:enter_insert_start_of_line, "Insert at start of line"},
      ~K(o) => {:insert_line_below, "Open line below"},
      ~K(O) => {:insert_line_above, "Open line above"},
      ~K(v) => {:enter_visual, "Visual mode (characterwise)"},
      ~K(V) => {:enter_visual_line, "Visual mode (linewise)"},
      ~K(R) => {:enter_replace_mode, "Replace mode"},
      ~K(:) => {:enter_command, "Command mode"},
      ~K(M-:) => {:enter_eval, "Eval mode (M-:)"},
      # ── Operators ─────────────────────────────────────────────────────────
      ~K(d) => {:operator_delete, "Delete (d{motion})"},
      ~K(c) => {:operator_change, "Change (c{motion})"},
      ~K(y) => {:operator_yank, "Yank (y{motion})"},
      ~K(p) => {:paste_after, "Paste after cursor"},
      ~K(P) => {:paste_before, "Paste before cursor"},
      ~K(x) => {:delete_chars_at, "Delete character at cursor"},
      ~K(X) => {:delete_chars_before, "Delete character before cursor"},
      ~K(D) => {:delete_to_end, "Delete to end of line"},
      ~K(C) => {:change_to_end, "Change to end of line"},
      ~K(s) => {:substitute_char, "Substitute character"},
      ~K(S) => {:substitute_line, "Substitute line"},
      ~K(J) => {:join_lines, "Join lines"},
      ~K(K) => {:hover, "Hover documentation"},
      ~K(~) => {:toggle_case, "Toggle case"},
      ~K(r) => {:pending_replace_char, "Replace character (r{char})"},
      ~K(>) => {:indent, "Indent (>{motion})"},
      ~K(<) => {:dedent, "Dedent (<{motion})"},
      # ── Undo / Redo ───────────────────────────────────────────────────────
      ~K(u) => {:undo, "Undo"},
      ~K(C-r) => {:redo, "Redo"},
      # ── Search ────────────────────────────────────────────────────────────
      ~K(/) => {:search_forward, "Search forward"},
      ~K(?) => {:search_backward, "Search backward"},
      ~K(n) => {:search_next, "Next search result"},
      ~K(N) => {:search_prev, "Previous search result"},
      ~K(*) => {:search_word_forward, "Search word under cursor (forward)"},
      ~K(#) => {:search_word_backward, "Search word under cursor (backward)"},
      # ── Registers ─────────────────────────────────────────────────────────
      ~K(") => {:pending_register, "Select register (\"{reg})"},
      # ── Marks ─────────────────────────────────────────────────────────────
      ~K(m) => {:pending_set_mark, "Set mark (m{a-z})"},
      ~K(') => {:pending_jump_mark_line, "Jump to mark line ('{a-z})"},
      ~K(`) => {:pending_jump_mark_exact, "Jump to mark exact (`{a-z})"},
      # ── Macros ────────────────────────────────────────────────────────────
      ~K(q) => {:toggle_macro_recording, "Record/stop macro (q{a-z})"},
      ~K(@) => {:replay_macro, "Replay macro (@{a-z})"},
      # ── Misc ──────────────────────────────────────────────────────────────
      ~K(.) => {:dot_repeat, "Repeat last change"},
      # ── Multi-key ─────────────────────────────────────────────────────────
      ~K(g) => {:prefix_g, "g prefix (gg = go to start)"}
    }
  end

  @doc """
  Returns filetype-scoped bindings for the `SPC m` major mode prefix.

  Each entry is `{filetype, key_sequence, command, description}` where
  key_sequence is relative to the `SPC m` prefix.

  These bindings are grouped by filetype and built into per-filetype
  tries at startup by `Minga.Keymap.Active`.
  """
  @type filetype_binding ::
          {atom(), [Bindings.key()], atom(), String.t()}

  @spec filetype_bindings() :: [filetype_binding()]
  def filetype_bindings do
    supported_filetypes = [
      :elixir,
      :ruby,
      :typescript,
      :typescript_react,
      :javascript,
      :javascript_react,
      :c,
      :cpp,
      :swift
    ]

    # SPC m a → alternate file for all supported filetypes
    alternate_bindings =
      Enum.map(supported_filetypes, fn ft ->
        {ft, ~k(a), :alternate_file, "Alternate file"}
      end)

    # SPC m t → +test submenu for all supported filetypes
    test_bindings =
      for ft <- supported_filetypes do
        [
          {ft, ~k(t t), :test_file, "Test file"},
          {ft, ~k(t a), :test_all, "Test all"},
          {ft, ~k(t p), :test_at_point, "Test at point"},
          {ft, ~k(t r), :test_rerun, "Rerun last test"},
          {ft, ~k(t o), :test_output, "Show test output"}
        ]
      end

    alternate_bindings ++ List.flatten(test_bindings)
  end

  @doc """
  Returns group prefixes for filetype-scoped bindings.

  These add labels to intermediate keys so which-key shows them
  (e.g., `t` → `+test` under `SPC m`).
  """
  @spec filetype_group_prefixes() :: [{[Bindings.key()], String.t()}]
  def filetype_group_prefixes do
    [
      {~k(t), "+test"}
    ]
  end
end
