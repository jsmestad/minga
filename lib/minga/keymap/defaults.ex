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
  | `SPC p`   | +project    |
  | `SPC q`   | +quit       |
  | `SPC h`   | +help       |
  """

  alias Minga.Keymap.Bindings

  @none 0x00

  # ---------------------------------------------------------------------------
  # Leaf bindings: {key_sequence, command_atom, description}
  # Key sequences are relative to the leader key (SPC is implicit).
  # ---------------------------------------------------------------------------

  @leader_bindings [
    # ── Command palette ──────────────────────────────────────────────────────
    {[{?:, @none}], :command_palette, "Execute command"},

    # ── Search ─────────────────────────────────────────────────────────────────
    {[{?s, @none}, {?p, @none}], :search_project, "Search project"},
    {[{?/, @none}], :search_project, "Search project"},

    # ── File ──────────────────────────────────────────────────────────────────
    {[{?f, @none}, {?f, @none}], :find_file, "Find file"},
    {[{?f, @none}, {?s, @none}], :save, "Save file"},
    {[{?f, @none}, {?p, @none}], :open_config, "Open config file"},

    # ── Buffer ────────────────────────────────────────────────────────────────
    {[{?b, @none}, {?b, @none}], :buffer_list, "Switch buffer"},
    {[{?b, @none}, {?B, @none}], :buffer_list_all, "Switch buffer (all)"},
    {[{?b, @none}, {?n, @none}], :buffer_next, "Next buffer"},
    {[{?b, @none}, {?p, @none}], :buffer_prev, "Previous buffer"},
    {[{?b, @none}, {?d, @none}], :kill_buffer, "Kill buffer"},
    {[{?b, @none}, {?m, @none}], :view_messages, "View messages"},
    {[{?b, @none}, {?W, @none}], :view_warnings, "View warnings"},
    {[{?b, @none}, {?N, @none}], :new_buffer, "New buffer"},
    {[{?b, @none}, {?l, @none}], :set_language, "Set language"},

    # ── Window ────────────────────────────────────────────────────────────────
    {[{?w, @none}, {?h, @none}], :window_left, "Window left"},
    {[{?w, @none}, {?j, @none}], :window_down, "Window down"},
    {[{?w, @none}, {?k, @none}], :window_up, "Window up"},
    {[{?w, @none}, {?l, @none}], :window_right, "Window right"},
    {[{?w, @none}, {?v, @none}], :split_vertical, "Vertical split"},
    {[{?w, @none}, {?s, @none}], :split_horizontal, "Horizontal split"},
    {[{?w, @none}, {?d, @none}], :window_close, "Close window"},

    # ── Quit ──────────────────────────────────────────────────────────────────
    {[{?q, @none}, {?q, @none}], :quit_all, "Quit editor"},

    # ── Help ──────────────────────────────────────────────────────────────────
    {[{?h, @none}, {?k, @none}], :describe_key, "Describe key"},
    {[{?h, @none}, {?r, @none}], :reload_config, "Reload config"},
    {[{?h, @none}, {?t, @none}], :theme_picker, "Pick theme"},
    {[{?h, @none}, {?e, @none}, {?l, @none}], :extension_list, "List extensions"},
    {[{?h, @none}, {?e, @none}, {?u, @none}], :extension_update_all, "Update all extensions"},
    {[{?h, @none}, {?e, @none}, {?U, @none}], :extension_update, "Update extension"},

    # ── Code ────────────────────────────────────────────────────────────────────
    {[{?c, @none}, {?d, @none}], :diagnostics_list, "List diagnostics"},
    {[{?c, @none}, {?f, @none}], :format_buffer, "Format buffer"},
    {[{?c, @none}, {?g, @none}], :goto_definition, "Go to definition"},
    {[{?c, @none}, {?k, @none}], :hover, "Hover documentation"},
    {[{?c, @none}, {?l, @none}, {?i, @none}], :lsp_info, "LSP info"},
    {[{?c, @none}, {?l, @none}, {?r, @none}], :lsp_restart, "Restart LSP"},
    {[{?c, @none}, {?l, @none}, {?s, @none}], :lsp_stop, "Stop LSP"},
    {[{?c, @none}, {?l, @none}, {?S, @none}], :lsp_start, "Start LSP"},

    # ── Git ──────────────────────────────────────────────────────────────────────
    {[{?g, @none}, {?s, @none}], :git_stage_hunk, "Stage hunk"},
    {[{?g, @none}, {?r, @none}], :git_revert_hunk, "Revert hunk"},
    {[{?g, @none}, {?p, @none}], :git_preview_hunk, "Preview hunk"},
    {[{?g, @none}, {?b, @none}], :git_blame_line, "Blame line"},

    # ── Project ────────────────────────────────────────────────────────────────
    {[{?p, @none}, {?f, @none}], :project_find_file, "Find file in project"},
    {[{?p, @none}, {?p, @none}], :project_switch, "Switch project"},
    {[{?p, @none}, {?i, @none}], :project_invalidate, "Invalidate project cache"},
    {[{?p, @none}, {?a, @none}], :project_add, "Add known project"},
    {[{?p, @none}, {?d, @none}], :project_remove, "Remove known project"},
    {[{?p, @none}, {?R, @none}], :project_recent_files, "Recent files in project"},

    # ── Open ──────────────────────────────────────────────────────────────────
    {[{?o, @none}, {?p, @none}], :toggle_file_tree, "Toggle file tree"},

    # ── AI agent ─────────────────────────────────────────────────────────────
    {[{?a, @none}, {?a, @none}], :toggle_agentic_view, "Toggle agent split"},
    {[{?a, @none}, {?t, @none}], :toggle_agentic_view, "Toggle agent split"},
    {[{?a, @none}, {?v, @none}], :toggle_agent_split, "Toggle agent split pane"},
    {[{?a, @none}, {?s, @none}], :agent_abort, "Stop agent"},
    {[{?a, @none}, {?n, @none}], :agent_new_session, "New agent session"},
    {[{?a, @none}, {?m, @none}], :agent_pick_model, "Pick agent model"},
    {[{?a, @none}, {?M, @none}], :agent_cycle_model, "Cycle agent model"},
    {[{?a, @none}, {?h, @none}], :agent_session_history, "Session history"},
    {[{?a, @none}, {?T, @none}], :agent_cycle_thinking, "Cycle thinking level"},
    {[{?a, @none}, {?e, @none}], :agent_summarize, "Summarize session to artifact"},
    {[{?a, @none}, {?q, @none}], :agent_dequeue, "Dequeue queued messages to editor"},
    {[{?a, @none}, {?f, @none}], :agent_queue_follow_up, "Queue current input as follow-up"},

    # ── Tab ──────────────────────────────────────────────────────────────────
    {[{9, @none}, {?n, @none}], :tab_next, "Next tab"},
    {[{9, @none}, {?p, @none}], :tab_prev, "Previous tab"},
    {[{9, @none}, {?d, @none}], :kill_buffer, "Close tab"},
    {[{9, @none}, {?a, @none}], :cycle_agent_tabs, "Next agent tab"},

    # ── Direct tab switching (SPC 1..9) ──────────────────────────────────────
    {[{?1, @none}], :tab_goto_1, "Tab 1"},
    {[{?2, @none}], :tab_goto_2, "Tab 2"},
    {[{?3, @none}], :tab_goto_3, "Tab 3"},
    {[{?4, @none}], :tab_goto_4, "Tab 4"},
    {[{?5, @none}], :tab_goto_5, "Tab 5"},
    {[{?6, @none}], :tab_goto_6, "Tab 6"},
    {[{?7, @none}], :tab_goto_7, "Tab 7"},
    {[{?8, @none}], :tab_goto_8, "Tab 8"},
    {[{?9, @none}], :tab_goto_9, "Tab 9"},

    # ── Toggle ────────────────────────────────────────────────────────────────
    {[{?t, @none}, {?l, @none}], :cycle_line_numbers, "Toggle line numbers"},
    {[{?t, @none}, {?p, @none}], :toggle_bottom_panel, "Toggle bottom panel"},
    {[{?t, @none}, {?w, @none}], :toggle_wrap, "Toggle word wrap"}
  ]

  # Group prefix descriptions shown in which-key at the SPC level.
  @group_prefixes [
    {[{9, @none}], "+tab"},
    {[{?s, @none}], "+search"},
    {[{?f, @none}], "+file"},
    {[{?b, @none}], "+buffer"},
    {[{?p, @none}], "+project"},
    {[{?c, @none}], "+code"},
    {[{?c, @none}, {?l, @none}], "+LSP"},
    {[{?g, @none}], "+git"},
    {[{?w, @none}], "+window"},
    {[{?q, @none}], "+quit"},
    {[{?h, @none}], "+help"},
    {[{?h, @none}, {?e, @none}], "+extensions"},
    {[{?o, @none}], "+open"},
    {[{?a, @none}], "+ai"},
    {[{?t, @none}], "+toggle"},
    {[{?m, @none}], "+filetype"}
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
  def leader_key, do: {32, @none}

  @doc """
  Returns all leader bindings as a flat list of `{key_sequence, command, description}` tuples.
  """
  @spec all_bindings() :: [{[Bindings.key()], atom(), String.t()}]
  def all_bindings, do: @leader_bindings

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
      {?h, 0} => {:move_left, "Move cursor left"},
      {?j, 0} => {:move_down, "Move cursor down"},
      {?k, 0} => {:move_up, "Move cursor up"},
      {?l, 0} => {:move_right, "Move cursor right"},
      {?0, 0} => {:move_to_line_start, "Move to line start"},
      {?$, 0} => {:move_to_line_end, "Move to line end"},
      {?^, 0} => {:move_to_first_non_blank, "First non-blank character"},
      {?G, 0} => {:move_to_document_end, "Go to end of document"},
      {?w, 0} => {:word_forward, "Word forward"},
      {?b, 0} => {:word_backward, "Word backward"},
      {?e, 0} => {:word_end, "Word end"},
      {?W, 0} => {:word_forward_big, "WORD forward"},
      {?B, 0} => {:word_backward_big, "WORD backward"},
      {?E, 0} => {:word_end_big, "WORD end"},
      {?%, 0} => {:match_bracket, "Match bracket"},
      {?{, 0} => {:paragraph_backward, "Paragraph backward"},
      {?}, 0} => {:paragraph_forward, "Paragraph forward"},
      {?H, 0} => {:move_to_screen_top, "Screen top"},
      {?M, 0} => {:move_to_screen_middle, "Screen middle"},
      {?L, 0} => {:move_to_screen_bottom, "Screen bottom"},
      {?+, 0} => {:next_line_first_non_blank, "Next line first non-blank"},
      {?-, 0} => {:prev_line_first_non_blank, "Previous line first non-blank"},
      # ── Find char ─────────────────────────────────────────────────────────
      {?f, 0} => {:pending_find_forward, "Find char forward (f{char})"},
      {?F, 0} => {:pending_find_backward, "Find char backward (F{char})"},
      {?t, 0} => {:pending_till_forward, "Till char forward (t{char})"},
      {?T, 0} => {:pending_till_backward, "Till char backward (T{char})"},
      {?;, 0} => {:repeat_find_char, "Repeat last find char"},
      {?,, 0} => {:repeat_find_char_reverse, "Repeat last find char (reverse)"},
      # ── Scrolling ─────────────────────────────────────────────────────────
      {?d, 0x02} => {:half_page_down, "Half page down"},
      {?u, 0x02} => {:half_page_up, "Half page up"},
      {?f, 0x02} => {:page_down, "Page down"},
      {?b, 0x02} => {:page_up, "Page up"},
      # ── Mode transitions ──────────────────────────────────────────────────
      {?i, 0} => {:enter_insert, "Insert before cursor"},
      {?a, 0} => {:enter_insert_after, "Insert after cursor"},
      {?A, 0} => {:enter_insert_end_of_line, "Insert at end of line"},
      {?I, 0} => {:enter_insert_start_of_line, "Insert at start of line"},
      {?o, 0} => {:insert_line_below, "Open line below"},
      {?O, 0} => {:insert_line_above, "Open line above"},
      {?v, 0} => {:enter_visual, "Visual mode (characterwise)"},
      {?V, 0} => {:enter_visual_line, "Visual mode (linewise)"},
      {?R, 0} => {:enter_replace_mode, "Replace mode"},
      {?:, 0} => {:enter_command, "Command mode"},
      {?:, 0x04} => {:enter_eval, "Eval mode (M-:)"},
      # ── Operators ─────────────────────────────────────────────────────────
      {?d, 0} => {:operator_delete, "Delete (d{motion})"},
      {?c, 0} => {:operator_change, "Change (c{motion})"},
      {?y, 0} => {:operator_yank, "Yank (y{motion})"},
      {?p, 0} => {:paste_after, "Paste after cursor"},
      {?P, 0} => {:paste_before, "Paste before cursor"},
      {?x, 0} => {:delete_chars_at, "Delete character at cursor"},
      {?X, 0} => {:delete_chars_before, "Delete character before cursor"},
      {?D, 0} => {:delete_to_end, "Delete to end of line"},
      {?C, 0} => {:change_to_end, "Change to end of line"},
      {?s, 0} => {:substitute_char, "Substitute character"},
      {?S, 0} => {:substitute_line, "Substitute line"},
      {?J, 0} => {:join_lines, "Join lines"},
      {?K, 0} => {:hover, "Hover documentation"},
      {?~, 0} => {:toggle_case, "Toggle case"},
      {?r, 0} => {:pending_replace_char, "Replace character (r{char})"},
      {?>, 0} => {:indent, "Indent (>{motion})"},
      {?<, 0} => {:dedent, "Dedent (<{motion})"},
      # ── Undo / Redo ───────────────────────────────────────────────────────
      {?u, 0} => {:undo, "Undo"},
      {?r, 0x02} => {:redo, "Redo"},
      # ── Search ────────────────────────────────────────────────────────────
      {?/, 0} => {:search_forward, "Search forward"},
      {??, 0} => {:search_backward, "Search backward"},
      {?n, 0} => {:search_next, "Next search result"},
      {?N, 0} => {:search_prev, "Previous search result"},
      {?*, 0} => {:search_word_forward, "Search word under cursor (forward)"},
      {?#, 0} => {:search_word_backward, "Search word under cursor (backward)"},
      # ── Registers ─────────────────────────────────────────────────────────
      {?", 0} => {:pending_register, "Select register (\"{reg})"},
      # ── Marks ─────────────────────────────────────────────────────────────
      {?m, 0} => {:pending_set_mark, "Set mark (m{a-z})"},
      {?', 0} => {:pending_jump_mark_line, "Jump to mark line ('{a-z})"},
      {?`, 0} => {:pending_jump_mark_exact, "Jump to mark exact (`{a-z})"},
      # ── Macros ────────────────────────────────────────────────────────────
      {?q, 0} => {:toggle_macro_recording, "Record/stop macro (q{a-z})"},
      {?@, 0} => {:replay_macro, "Replay macro (@{a-z})"},
      # ── Misc ──────────────────────────────────────────────────────────────
      {?., 0} => {:dot_repeat, "Repeat last change"},
      # ── Multi-key ─────────────────────────────────────────────────────────
      {?g, 0} => {:prefix_g, "g prefix (gg = go to start)"}
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
        {ft, [{?a, @none}], :alternate_file, "Alternate file"}
      end)

    # SPC m t → +test submenu for all supported filetypes
    test_bindings =
      for ft <- supported_filetypes do
        [
          {ft, [{?t, 0}, {?t, 0}], :test_file, "Test file"},
          {ft, [{?t, 0}, {?a, 0}], :test_all, "Test all"},
          {ft, [{?t, 0}, {?p, 0}], :test_at_point, "Test at point"},
          {ft, [{?t, 0}, {?r, 0}], :test_rerun, "Rerun last test"},
          {ft, [{?t, 0}, {?o, 0}], :test_output, "Show test output"}
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
      {[{?t, 0}], "+test"}
    ]
  end
end
