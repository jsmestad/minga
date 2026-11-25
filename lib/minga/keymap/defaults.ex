defmodule Minga.Keymap.Defaults do
  @moduledoc """
  Doom Emacs-style default leader keybindings for Minga.

  All bindings are rooted at the **SPC** (space) leader key in Normal mode.
  Group prefix nodes carry Title Case labels ("Files", "Session"); which-key
  renders them as groups with a trailing `›`. `docs/design/keys.md` is the
  authority for where each key lives.

  ## Key groups

  | Prefix    | Group       |
  |-----------|-------------|
  | `SPC f`   | Files       |
  | `SPC b`   | Buffers     |
  | `SPC w`   | Windows     |
  | `SPC s`   | Search      |
  | `SPC c`   | Code        |
  | `SPC g`   | Git         |
  | `SPC o`   | Open        |
  | `SPC a`   | Minga       |
  | `SPC t`   | Toggles     |
  | `SPC p`   | Project     |
  | `SPC q`   | Quit        |
  | `SPC h`   | Help        |
  | `SPC m`   | Filetype    |
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

    # ── Eval ──────────────────────────────────────────────────────────────────
    {~k(;), :enter_eval, "Eval expression"},

    # ── Search ─────────────────────────────────────────────────────────────────
    {~k(s p), :search_project, "Search project"},
    {~k(s s), :search_buffer, "Search in buffer"},
    {~k(s t), :search_todos, "Search TODOs"},
    {~k(s r), :search_and_replace, "Search and replace"},
    {~k(s i), :document_symbols, "Document symbols"},
    {~k(s j), :jump_list, "Jump list"},
    {~k(s u), :timeline_toggle, "Edit timeline"},
    {~k(s w), :workspace_symbols, "Search workspace symbols"},
    {~k(/), :search_project, "Search project"},

    # ── File ──────────────────────────────────────────────────────────────────
    {~k(f f), :find_file, "Find file"},
    {~k(f F), :find_file_other_window, "Find file other window"},
    {~k(f o), :remote_find_file, "Open remote file"},
    {~k(f s), :save, "Save file"},
    {~k(f p), :open_config, "Open config file"},

    # ── Buffer ────────────────────────────────────────────────────────────────
    {~k(,), :buffer_list, "Switch buffer"},
    {~k(b b), :buffer_list, "Switch buffer"},
    {~k(b B), :buffer_list_all, "Switch buffer (all)"},
    {~k(b n), :buffer_next, "Next buffer"},
    {~k(b p), :buffer_prev, "Previous buffer"},
    {~k(b d), :kill_buffer, "Kill buffer"},
    {~k(b X), :force_kill_buffer, "Force kill buffer"},
    {~k(b D), :kill_other_buffers, "Close other buffers"},
    {~k(b K), :kill_all_buffers, "Close all buffers"},
    {~k(b m), :view_messages, "View messages"},
    {~k(b W), :view_warnings, "View warnings"},
    {~k(b N), :new_buffer, "New buffer"},
    {~k(b l), :set_language, "Set language"},

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
    {~k(q u), :unsaved_text, "Unsaved text"},

    # ── Help ──────────────────────────────────────────────────────────────────
    {~k(h a), :apropos, "Apropos"},
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
    {~k(c d), :goto_definition, "Go to definition"},
    {~k(c D), :find_references, "Find references"},
    {~k(c f), :format_buffer, "Format buffer"},
    {~k(c i), :goto_implementation, "Go to implementation"},
    {~k(c k), :hover, "Hover documentation"},
    {~k(c r), :rename_symbol, "Rename symbol"},
    {~k(c t), :goto_type_definition, "Go to type definition"},
    {~k(c x), :diagnostics_list, "List diagnostics"},
    {~k(c h), :call_hierarchy, "Call hierarchy (incoming)"},
    {~k(c H), :call_hierarchy_outgoing, "Call hierarchy (outgoing)"},
    {~k(c v), :selection_expand, "Expand selection"},
    {~k(c V), :selection_shrink, "Shrink selection"},
    {~k(c l i), :lsp_info, "LSP info"},
    {~k(c l r), :lsp_restart, "Restart LSP"},
    {~k(c l s), :lsp_stop, "Stop LSP"},
    {~k(c l S), :lsp_start, "Start LSP"},
    {~k(c l I), :tool_manage, "Manage tools"},

    # ── Project ────────────────────────────────────────────────────────────────
    {~k(SPC), :project_find_file, "Find file in project"},
    {~k(p f), :project_find_file, "Find file in project"},
    {~k(p p), :project_switch, "Switch project"},
    {~k(p i), :project_invalidate, "Invalidate project cache"},
    {~k(p a), :project_add, "Add known project"},
    {~k(p d), :project_remove, "Remove known project"},
    {~k(p r), :project_recent_files, "Recent files in project"},
    {~k(p .), :project_browse, "Browse project"},
    {~k(p T), :test_all, "Test project"},

    # ── Open ──────────────────────────────────────────────────────────────────
    {~k(o b), :toggle_beam_observatory, "BEAM observatory"},
    {~k(o p), :toggle_file_tree, "Toggle file tree"},
    {~k(o r), :tree_reveal_active, "Reveal file in tree"},

    # ── Minga (SPC a): everyday keys at the top, the rest in three groups ────
    {~k(a a), :toggle_agentic_view, "Agent view"},
    {~k(a n), :agent_new_session, "New session"},
    {~k(a s), :agent_abort, "Stop"},
    {~k(a u), :undo_agent_session, "Undo all agent edits"},
    {~k(a v), :toggle_agent_split, "Conversation split"},
    {~k(a ?), :inline_ask, "Ask about this"},
    {~k(a r), :workspace_pending_reviews, "Pending reviews"},
    {~k(a e), :inline_edit, "Rewrite selection"},
    {~k(a W), :code_why, "Why this line"},
    {~k(a A), :code_autobiography, "Code autobiography"},
    {~k(a p), :agent_edits_decide, "Publish edits…"},

    # SPC a q: Queue
    {~k(a q q), :agent_queued_inputs, "Open queue"},
    {~k(a q f), :agent_queue_follow_up, "Queue as follow-up"},

    # SPC a x: Context
    {~k(a x b), :agent_attach_buffer, "Attach this buffer"},
    {~k(a x f), :agent_attach_file, "Attach a project file"},
    {~k(a x d), :agent_attach_diagnostics, "Attach diagnostics"},
    {~k(a x l), :agent_draft_attachments, "List attachments"},

    # SPC a S: Session
    {~k(a S h), :agent_session_history, "Resume a session"},
    {~k(a S R), :agent_session_rename, "Rename session"},
    {~k(a S m), :agent_pick_model, "Pick model"},
    {~k(a S t), :agent_pick_thinking, "Pick thinking level"},
    {~k(a S l), :agent_start_session_picker, "Pick where it runs"},
    {~k(a S H), :agent_retained_history, "Read retained messages"},
    {~k(a S k), :agent_checklist, "Inspect checklist"},
    {~k(a S s), :agent_stop_session, "Stop session"},

    # ── Workspace (SPC TAB) ──────────────────────────────────────────────────
    {~k(TAB TAB), :workspace_toggle, "Toggle workspace"},
    {~k(TAB N), :workspace_next, "Next workspace"},
    {~k(TAB P), :workspace_prev, "Previous workspace"},
    {~k(TAB A), :workspace_next_agent, "Next agent workspace"},
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
    {~k(t w), :toggle_wrap, "Toggle word wrap"}
  ]

  # Group labels shown in which-key. They read like leaves: Title Case, never a
  # leading `+`. The which-key builder marks them as groups and adds the `›`.
  @group_prefixes [
    {~k(TAB), "Workspace"},
    {~k(s), "Search"},
    {~k(f), "Files"},
    {~k(b), "Buffers"},
    {~k(p), "Project"},
    {~k(c), "Code"},
    {~k(c l), "LSP"},
    {~k(g), "Git"},
    {~k(g c), "Commit"},
    {~k(g x), "Conflict"},
    {~k(g z), "Stash"},
    {~k(w), "Windows"},
    {~k(q), "Quit"},
    {~k(h), "Help"},
    {~k(h e), "Extensions"},
    {~k(o), "Open"},
    {~k(a), "Minga"},
    {~k(a q), "Queue"},
    {~k(a x), "Context"},
    {~k(a S), "Session"},
    {~k(t), "Toggles"},
    {~k(m), "Filetype"}
  ]

  # Which-key sections, by the prefix they belong to (formatted, without the
  # leader). Each section is a column with a dim name above it; keys are listed
  # in display order. A bound key no section lists joins a trailing "More"
  # section; a listed key that is not bound is skipped. Prefixes without an
  # entry here get one unnamed section. See docs/design/surfaces.md.
  @which_key_sections %{
    "" => [
      {"Groups", ~w(a s c g f b w o h t q)},
      {"Often", ["SPC", ",", "/", ":"]}
    ],
    "a" => [
      {"Tasks", ~w(a n i w s)},
      {"Conversation", ~w(v ? e q)},
      {"Changes", ~w(r y d u p)},
      {"More", ~w(x S W A)}
    ]
  }

  # macOS platform keys, as aliases of the command they run without a modifier
  # (docs/design/keys.md, rule 5). Which-key shows them beside the entry and the
  # macOS menu bar puts them in the shortcut column, so the two teach each other.
  @platform_keys %{
    save: "⌘S",
    undo: "⌘Z",
    quit: "⌘W",
    quit_all: "⌘Q",
    jump_back: "⌘[",
    jump_forward: "⌘]"
  }

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
  Returns the which-key sections for a leader prefix, as `{name, formatted_keys}` in display order.

  `prefix` is the formatted sequence after the leader (`""` for `SPC` itself, `"a"` for `SPC a`). An empty list means the prefix declares no sections.
  """
  @spec which_key_sections(String.t()) :: [{String.t(), [String.t()]}]
  def which_key_sections(prefix) when is_binary(prefix),
    do: Map.get(@which_key_sections, prefix, [])

  @doc "Returns the macOS ⌘ equivalent of `command` (`\"⌘S\"`), or nil when it has none."
  @spec platform_key(atom() | tuple() | nil) :: String.t() | nil
  def platform_key(command) when is_atom(command), do: Map.get(@platform_keys, command)
  def platform_key(_command), do: nil

  @doc "Returns every macOS ⌘ equivalent, keyed by the command it runs."
  @spec platform_keys() :: %{atom() => String.t()}
  def platform_keys, do: @platform_keys

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
      # ⌥h ⌥j ⌥k ⌥l alias SPC c v, ] n, [ n and SPC c V (docs/design/keys.md).
      ~K(M-h) => {:selection_expand, "Expand selection (SPC c v)"},
      ~K(M-l) => {:selection_shrink, "Shrink selection (SPC c V)"},
      ~K(M-j) => {:nav_next_sibling, "Next syntax node (]n)"},
      ~K(M-k) => {:nav_prev_sibling, "Previous syntax node ([n)"},
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
      # ⌘Z aliases u (docs/design/keys.md, rule 5). The macOS app runs Undo from its menu, so this key reaches the
      # keymap only from a terminal that reports ⌘ (the Kitty keyboard protocol).
      {?z, 0x08} => {:undo, "Undo (u)"},
      ~K(C-r) => {:redo, "Redo"},
      # ── Jump list ─────────────────────────────────────────────────────────
      ~K(C-o) => {:jump_back, "Jump back (jump list)"},
      ~K(C-i) => {:jump_forward, "Jump forward (jump list)"},
      ~K(TAB) => {:jump_forward, "Jump forward (jump list)"},
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
  (e.g., `t` → "Test" under `SPC m`).
  """
  @spec filetype_group_prefixes() :: [{[Bindings.key()], String.t()}]
  def filetype_group_prefixes do
    [
      {~k(t), "Test"}
    ]
  end
end
