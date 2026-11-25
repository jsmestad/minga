defmodule Minga.Keymap.Scope.Agent do
  @moduledoc """
  Keymap scope for the full-screen agentic view.

  Provides vim-like navigation, fold/collapse, copy, search, and panel
  management bindings. In normal mode, keys like `j`/`k` scroll the chat,
  `y`/`Y` copy content, and prefix sequences (`z`, `g`, `]`, `[`) provide
  fold, go-to, and bracket navigation.

  The composer is a buffer with Vim editing. It starts in Insert, where `↩` adds a newline and printable characters type. In the composer's Normal mode, `↩` sends; `⌘↩` sends from either state, and sending while Minga works steers the current turn. `⌥↩` queues the next message and `⌘.` stops Minga. Ctrl+C and ESC return to Normal mode; Ctrl+C also stops a working turn.

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
  alias Minga.Keymap.Defaults

  import Minga.Keymap.Sigil

  # Modifier bitmasks
  @shift 0x01
  @ctrl 0x02
  @alt 0x04
  @cmd 0x08

  # Special codepoints
  @enter 13
  @backspace 127
  # Arrow keys: Kitty protocol (both frontends) and legacy macOS NSEvent codes.
  @arrow_up 57_352
  @arrow_down 57_353
  @ns_arrow_up 0xF700
  @ns_arrow_down 0xF701

  # Group specs for each vim state.
  @insert_groups [:ctrl_agent_common, :newline_variants]
  @input_normal_groups [:ctrl_agent_common]
  @cua_groups [:newline_variants, {:cua_navigation, exclude: [:half_page_up, :half_page_down]}]

  # ── Behaviour callbacks ────────────────────────────────────────────────────

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(:normal, context) do
    normal_trie()
    |> merge_trie(start_remedy_keymap(:chat, context))
    |> bind_diff_review_keys(:vim, context)
  end

  def keymap(:insert, _context), do: insert_trie()

  def keymap(:input_normal, context),
    do: merge_trie(input_normal_trie(), start_remedy_keymap(:composer, context))

  def keymap(:cua, context) do
    cua_trie()
    |> merge_trie(start_remedy_keymap(:cua, context))
    |> bind_diff_review_keys(:cua, context)
  end

  def keymap(_state, _context), do: Bindings.new()

  @typedoc "The remedy a failed Agent start offers, passed as the `:agent_start_remedy` context."
  @type start_remedy :: :retry | :set_up_provider

  @typedoc """
  Where keys go: Vim chat navigation, the Vim composer in Normal (`:composer`) or Insert (`:composer_insert`), or the CUA Agent view, which has one trie for chat and composer.
  """
  @type start_remedy_focus :: :chat | :composer | :composer_insert | :cua

  # One table names, for each focus, the key that runs a failed start's remedy,
  # the command it runs and the hint frontends show. Enter goes through prompt
  # submit, which runs the remedy unless the draft is a known slash command. In
  # the composer's Insert, Enter adds a newline, so the hint names Escape first
  # and Insert binds nothing more. `r` in chat navigation has no draft to protect
  # and runs the remedy itself.
  @start_remedy_keys %{
    chat: {"r", :agent_start_remedy, "r"},
    composer: {"RET", :agent_submit_or_newline, "Enter"},
    composer_insert: {nil, nil, "Esc, Enter"},
    cua: {"RET", :agent_submit_or_newline, "Enter"}
  }

  @doc """
  The key hint for running a failed start's remedy at the given focus: `r` in chat navigation, Enter in the composer.

  Both come from the same table as the bindings, so the hint names the key that works where focus is.
  """
  @spec start_remedy_key_hint(start_remedy_focus()) :: String.t()
  def start_remedy_key_hint(focus) do
    {_binding, _command, hint} = Map.fetch!(@start_remedy_keys, focus)
    hint
  end

  @doc """
  The remedy bindings at the given focus while the context offers a remedy, otherwise an empty trie.

  Chat navigation merges this into its `:normal` trie, so `r` runs the remedy and every other key, including `s` for the session switcher, keeps its meaning. The Vim composer merges it into its input-normal trie, so Enter runs the remedy from Normal; in Insert, Enter adds a newline and the trie is empty. CUA merges it into its single trie, so Enter submits from chat as well as from the composer. Prompt submit runs the remedy unless the draft is a known slash command.
  """
  @spec start_remedy_keymap(start_remedy_focus(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def start_remedy_keymap(focus, context) do
    case {Keyword.get(context, :agent_start_remedy), Map.fetch!(@start_remedy_keys, focus)} do
      {remedy, {binding, command, _hint}}
      when remedy in [:retry, :set_up_provider] and is_binary(binding) ->
        Bindings.bind(
          Bindings.new(),
          Minga.Keymap.KeyParser.parse!(binding),
          command,
          start_remedy_description(remedy)
        )

      _none ->
        Bindings.new()
    end
  end

  @typedoc "An action a staged Diff Review offers from the keyboard in both editing models."
  @type diff_review_action ::
          :next_hunk | :previous_hunk | :accept_hunk | :reject_hunk | :accept_all | :reject_all

  @typedoc """
  Which keys a Diff Review hint names: Vim keys, or CUA chords spelled with Cmd (native GUI) or Ctrl (terminal).

  CUA binds the Cmd and the Ctrl chord in every frontend; only the hint follows the frontend, because a terminal cannot send Cmd.
  """
  @type diff_review_key_set :: :vim | :cua_cmd | :cua_ctrl

  # One table names, for each Diff Review action, the command it runs, its help
  # text, the Vim keys and hint, and the CUA chords with their Cmd and Ctrl
  # hints. The bindings and every hint come from these rows, so a hint always
  # names a bound key. On a fork conflict, accept means "Use Agent version" and
  # reject means "Keep mine".
  #
  # CUA choices: Alt+Down/Alt+Up step through hunks in both frontends; function
  # keys such as F7 are never bound (key grammar rule 6). Cmd/Ctrl+Enter accepts
  # and Cmd/Ctrl+Backspace rejects, the keep/undo pair Cursor and VS Code agent
  # edits use; Shift widens either to every hunk. None of these chords types text
  # or has another meaning in the Agent scope, and Cmd+N (New Buffer) stays free.
  @diff_review_keys [
    {:next_hunk, :agent_next_code_block, "Next hunk", {[[{?], 0}, {?c, 0}]], "]c"},
     {[[{@arrow_down, @alt}], [{@ns_arrow_down, @alt}]], "Alt+Down", "Alt+Down"}},
    {:previous_hunk, :agent_prev_code_block, "Previous hunk", {[[{?[, 0}, {?c, 0}]], "[c"},
     {[[{@arrow_up, @alt}], [{@ns_arrow_up, @alt}]], "Alt+Up", "Alt+Up"}},
    {:accept_hunk, :agent_accept_hunk, "Accept hunk (Use Agent version)", {[[{?y, 0}]], "y"},
     {[[{@enter, @cmd}], [{@enter, @ctrl}]], "Cmd+Enter", "Ctrl+Enter"}},
    {:reject_hunk, :agent_reject_hunk, "Reject hunk (Keep mine)", {[[{?x, 0}]], "x"},
     {[[{@backspace, @cmd}], [{@backspace, @ctrl}]], "Cmd+Backspace", "Ctrl+Backspace"}},
    {:accept_all, :agent_accept_all_hunks, "Accept all hunks", {[[{?Y, 0}]], "Y"},
     {[[{@enter, @cmd + @shift}], [{@enter, @ctrl + @shift}]], "Cmd+Shift+Enter",
      "Ctrl+Shift+Enter"}},
    {:reject_all, :agent_reject_all_hunks, "Reject all hunks", {[[{?X, 0}]], "X"},
     {[[{@backspace, @cmd + @shift}], [{@backspace, @ctrl + @shift}]], "Cmd+Shift+Backspace",
      "Ctrl+Shift+Backspace"}}
  ]

  @doc """
  The key set a Diff Review hint uses for an editing model and frontend: Vim keys, or CUA chords spelled with Cmd in a native GUI and Ctrl in a terminal.
  """
  @spec diff_review_key_set(:vim | :cua, boolean()) :: diff_review_key_set()
  def diff_review_key_set(:vim, _native_gui?), do: :vim
  def diff_review_key_set(:cua, true), do: :cua_cmd
  def diff_review_key_set(:cua, false), do: :cua_ctrl

  @doc """
  The key hint for a Diff Review action in the given key set.

  The hint comes from the same table as the bindings, so it names a key that runs the action while the review has focus.
  """
  @spec diff_review_key_hint(diff_review_action(), diff_review_key_set()) :: String.t()
  def diff_review_key_hint(action, key_set) do
    {^action, _command, _description, {_vim_keys, vim_hint}, {_cua_keys, cmd_hint, ctrl_hint}} =
      List.keyfind!(@diff_review_keys, action, 0)

    case key_set do
      :vim -> vim_hint
      :cua_cmd -> cmd_hint
      :cua_ctrl -> ctrl_hint
    end
  end

  @doc "The help overlay group listing every Diff Review action with its key in the given key set."
  @spec diff_review_help_group(diff_review_key_set()) :: Minga.Keymap.Scope.help_group()
  def diff_review_help_group(key_set) do
    {"Diff Review",
     for {action, _command, description, _vim, _cua} <- @diff_review_keys do
       {diff_review_key_hint(action, key_set), description}
     end}
  end

  # Binds the editing model's Diff Review keys over the trie while the context
  # says a staged Diff Review has focus. Vim's `]c`/`[c` are bound anyway, so
  # rebinding them is a no-op; `y`, `x`, `Y` and `X` replace copy while reviewing.
  @spec bind_diff_review_keys(Bindings.node_t(), :vim | :cua, Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  defp bind_diff_review_keys(trie, model, context) do
    if Keyword.get(context, :agent_diff_review, false) do
      for {_action, command, description, vim, cua} <- @diff_review_keys,
          sequence <- diff_review_sequences(model, vim, cua),
          reduce: trie do
        acc -> Bindings.bind(acc, sequence, command, description)
      end
    else
      trie
    end
  end

  @spec diff_review_sequences(:vim | :cua, {[[Bindings.key()]], String.t()}, tuple()) ::
          [[Bindings.key()]]
  defp diff_review_sequences(:vim, {sequences, _hint}, _cua), do: sequences
  defp diff_review_sequences(:cua, _vim, {sequences, _cmd_hint, _ctrl_hint}), do: sequences

  @doc """
  The leader sequence that starts a new local Agent session, read from the given leader trie, or nil when the editing model cannot reach it.

  Vim reaches the leader from chat navigation. CUA reaches it only through the SPC chord, so with `space_leader: :off` CUA has no key for it. A user who rebinds or unbinds `:agent_new_session` changes the hint with the binding.
  """
  @spec new_session_key_hint(Bindings.node_t(), :vim | :cua, :chord | :off) :: String.t() | nil
  def new_session_key_hint(_leader_trie, :cua, :off), do: nil

  def new_session_key_hint(leader_trie, _editing_model, _space_leader) do
    case Bindings.sequences_for_command(leader_trie, :agent_new_session) do
      [keys | _longer] -> Bindings.format_sequence([Defaults.leader_key() | keys])
      [] -> nil
    end
  end

  @typedoc "Where the composer's keys go: Vim Insert, Vim Normal, another Vim mode (Visual, operator-pending, Replace), or the CUA composer."
  @type composer_focus :: :insert | :normal | :other_mode | :cua

  @typedoc """
  Facts that change the composer's hints: `:native_gui` (the macOS app can send ⌘), `:working` (this conversation has a turn to stop, so stop is offered; that includes a turn waiting for an approval), `:stopped` (sending continues the stopped task) and `:remedy` (a failed start binds ↩ in Normal to its remedy, which the chat shows with its own key, so nothing sends).
  """
  @type composer_hint_option ::
          {:native_gui, boolean()}
          | {:working, boolean()}
          | {:stopped, boolean()}
          | {:remedy, boolean()}

  @doc """
  The key hints the focused composer shows, most important first, as `{keys, action}` pairs.

  Each hint names a key this scope binds for that focus (or, for stop in the terminal, the leader key `SPC a s`), so a hint never promises a key that does nothing. A terminal cannot send ⌘, so the terminal hints name the keys it can send.
  """
  @spec composer_key_hints(composer_focus(), [composer_hint_option()]) :: [
          {String.t(), String.t()}
        ]
  def composer_key_hints(focus, opts \\ [])

  def composer_key_hints(focus, opts) when is_list(opts) do
    if Keyword.get(opts, :remedy, false),
      do: remedy_key_hints(focus),
      else: send_key_hints(focus, opts)
  end

  @spec remedy_key_hints(composer_focus()) :: [{String.t(), String.t()}]
  defp remedy_key_hints(:insert), do: [{"↩", "new line"}, {"esc", "normal"}]
  defp remedy_key_hints(_focus), do: []

  @spec send_key_hints(composer_focus(), [composer_hint_option()]) :: [{String.t(), String.t()}]
  defp send_key_hints(focus, opts) do
    native? = Keyword.get(opts, :native_gui, false)
    send = if Keyword.get(opts, :stopped, false), do: "continue", else: "send"
    stop = if Keyword.get(opts, :working, false), do: stop_hint(native?, focus), else: []

    case focus do
      :insert -> [insert_send_hint(native?, send), {"⌥↩", "queue"}] ++ stop ++ [{"esc", "normal"}]
      :normal -> [{"↩", send}] ++ stop ++ [{"i", "insert"}]
      # Visual and the other Vim modes keep every key for the edit under way: nothing sends or stops there.
      :other_mode -> [{"esc", "normal"}]
      :cua -> [{"↩", send}, {"⌥↩", "new line"}] ++ stop
    end
  end

  @spec insert_send_hint(boolean(), String.t()) :: {String.t(), String.t()}
  defp insert_send_hint(true, send), do: {"⌘↩", send}
  defp insert_send_hint(false, send), do: {"esc ↩", send}

  # The terminal has no ⌘: Normal reaches the leader and Insert stops with ⌃C.
  # Desktop shortcuts in the terminal have no stop key (⌃C copies there), so they
  # hint none.
  @spec stop_hint(boolean(), composer_focus()) :: [{String.t(), String.t()}]
  defp stop_hint(true, _focus), do: [{"⌘.", "stop"}]
  defp stop_hint(false, :normal), do: [{"SPC a s", "stop"}]
  defp stop_hint(false, :insert), do: [{"⌃C", "stop"}]
  defp stop_hint(false, :cua), do: []
  defp stop_hint(false, :other_mode), do: []

  @spec start_remedy_description(start_remedy()) :: String.t()
  defp start_remedy_description(:retry), do: "Retry Agent start"
  defp start_remedy_description(:set_up_provider), do: "Set up provider"

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
    # Navigation keys (j, k, G, Ctrl-D, Ctrl-U, etc.) are NOT bound here.
    # They pass through to AgentNav, which updates semantic transcript scroll state.
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
    |> Bindings.bind(~k(g b), :agent_provenance_return, "Back to source line")
    # z-prefix: domain fold/collapse commands
    |> Bindings.bind(~k(z A), :agent_toggle_all_collapse, "Toggle all collapsible blocks")
    # ]-prefix: semantic navigation (domain-specific)
    |> Bindings.bind(~k(] c), :agent_next_code_block, "Next code block/hunk")
    |> Bindings.bind(~k(] f), :timeline_next_file, "Next changed file")
    |> Bindings.bind(~k(] F), :timeline_browse_files, "Browse all changed files")
    # [-prefix: semantic navigation (domain-specific)
    |> Bindings.bind(~k([ c), :agent_prev_code_block, "Previous code block/hunk")
    |> Bindings.bind(~k([ f), :timeline_prev_file, "Previous changed file")
    # Copy (domain: structured copy, not raw yank)
    |> Bindings.bind(~k(y), :agent_copy_code_block, "Copy code block")
    |> Bindings.bind(~k(Y), :agent_copy_message, "Copy full message")
    # Input focus
    |> Bindings.bind(~k(i), :agent_focus_input, "Focus input")
    |> Bindings.bind(~k(a), :agent_focus_input, "Focus input")
    |> Bindings.bind(~k(A), :agent_focus_input, "Focus input (append)")
    |> Bindings.bind(~k(RET), :agent_focus_input, "Focus input")
    # Panel
    |> Bindings.bind(~k(}), :agent_grow_panel, "Grow chat panel")
    |> Bindings.bind(~k({), :agent_shrink_panel, "Shrink chat panel")
    |> Bindings.bind(~k(=), :agent_reset_panel, "Reset panel split")
    |> Bindings.bind(~k(TAB), :agent_switch_focus, "Switch panel focus")
    # Search keys are intentionally left unbound here for the input stack.
    # Session
    |> Bindings.bind(~k(s), :agent_session_switcher, "Session switcher")
    # Help
    |> Bindings.bind(~k(?), :agent_toggle_help, "Toggle help overlay")
    # Return to editor
    |> Bindings.bind(~k(q), :agent_close, "Return to editor")
    |> Bindings.bind(~k(ESC), :agent_dismiss_or_noop, "Dismiss/cancel")
    # Stop: the macOS platform alias of SPC a s
    |> Bindings.bind([{?., @cmd}], :agent_abort, "Stop")
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
        # Enter adds a newline while typing; sending is Normal-mode Enter or Cmd+Enter.
        |> Bindings.bind(~k(RET), :agent_insert_newline, "New line")
        |> Bindings.bind([{@enter, @alt}], :agent_queue_follow_up, "Queue next message")
        |> bind_composer_actions()
        # Backspace
        |> Bindings.bind(~k(DEL), :agent_input_backspace, "Delete character")
        # Left/right arrows handled by Vim.handle_key (shared primitive).
        # Up/down arrows handled here: moves cursor OR recalls prompt history.
        |> Bindings.bind([{0xF700, 0}], :agent_input_up, "Move up / history prev")
        |> Bindings.bind([{0xF701, 0}], :agent_input_down, "Move down / history next")
        |> Bindings.bind([{57_352, 0}], :agent_input_up, "Move up / history prev")
        |> Bindings.bind([{57_353, 0}], :agent_input_down, "Move down / history next")
      end
    )
  end

  # ── Input normal mode meta keys ──────────────────────────────────────────
  #
  # Vim editing keys (motions, operators, text objects, counts, visual mode)
  # are handled by the standard Mode FSM. The composer dispatch consults this
  # trie first, only in Vim Normal mode with no key sequence pending, so `q`
  # records a macro and `d` still waits for its motion.

  @spec input_normal_trie() :: Bindings.node_t()
  defp input_normal_trie do
    build_trie(
      groups: @input_normal_groups,
      then: fn trie ->
        trie
        # A second Escape leaves input-normal and returns focus to chat navigation.
        |> Bindings.bind(~k(ESC), :agent_unfocus_input, "Back to chat nav")
        |> Bindings.bind(~k(RET), :agent_submit_or_newline, "Send (steers while Minga works)")
        |> bind_composer_actions()
      end
    )
  end

  # Composer actions with the same keys in Insert and Normal: Cmd+Enter sends
  # (steering while Minga works) and Cmd+. stops Minga (the macOS platform alias
  # of SPC a s). Alt+Enter, which queues, is Insert only: the key grammar allows
  # it where you type (`docs/design/keys.md` rule 4); Normal queues with SPC a q f.
  @spec bind_composer_actions(Bindings.node_t()) :: Bindings.node_t()
  defp bind_composer_actions(trie) do
    trie
    |> Bindings.bind(
      [{@enter, @cmd}],
      :agent_submit_or_newline,
      "Send (steers while Minga works)"
    )
    |> Bindings.bind([{?., @cmd}], :agent_abort, "Stop")
  end

  # ── Help content ───────────────────────────────────────────────────────────

  @spec chat_help() :: [Minga.Keymap.Scope.help_group()]
  defp chat_help do
    [
      {"Tool approval (composer unfocused)",
       [
         {"Esc Esc (Vim)", "Leave INSERT, then leave prompt editing"},
         {"y / Enter", "Approve the displayed request once"},
         {"a", "Trust this tool for this session"},
         {"t", "Trust this tool for this turn"},
         {"n", "Deny the displayed request"},
         {"Esc", "Defer: the request stays pending"}
       ]},
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
         {"zA", "Toggle all collapsible blocks"}
       ]},
      {"Jump",
       [
         {"]c / [c", "Next / prev code block"},
         {"gb", "Back to source line (after SPC a W)"}
       ]},
      {"Copy",
       [
         {"y", "Copy code block at cursor"},
         {"Y", "Copy full message at cursor"}
       ]},
      {"Composer",
       [
         {"i / a / Enter", "Focus the composer"},
         {"Enter (Insert)", "New line"},
         {"Enter (Normal) / Cmd+Enter", "Send; steers while Minga works"},
         {"Alt+Enter", "Queue the next message"},
         {"Cmd+. / SPC a s", "Stop; the queue is kept"},
         {"Up / Down", "History / cursor in the composer"}
       ]},
      {"Session",
       [
         {"Ctrl-c", "Normal mode (also stops Minga while it works)"},
         {"s", "Session switcher"},
         {"SPC a n", "New local session"},
         {"SPC a q q", "Inspect queued inputs"},
         {"SPC a q f", "Queue follow-up from input"},
         {"SPC a S l", "Pick local/remote session"},
         {"SPC a S s", "Stop agent session"},
         {"SPC a S m", "Pick agent model"},
         {"SPC a S t", "Pick thinking level"},
         {"SPC a S k / /tasks", "Inspect the conversation checklist"},
         {"SPC f o", "Open remote file"}
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
        |> Bindings.bind([{@enter, @alt}], :agent_insert_newline, "Insert newline")
        |> Bindings.bind(~k(ESC), :agent_dismiss_or_noop, "Dismiss/cancel")
        |> Bindings.bind(~k(TAB), :agent_switch_focus, "Switch panel focus")
        # Stop: the macOS platform alias of SPC a s
        |> Bindings.bind([{?., @cmd}], :agent_abort, "Stop")
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
