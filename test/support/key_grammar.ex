defmodule Minga.Test.KeyGrammar do
  @moduledoc """
  Pure classifier for Minga's key grammar (design principle 11).

  `inventory/0` enumerates every built-in binding without starting the Editor: the leader list and `SPC m` filetype bindings from `Minga.Keymap.Defaults`, the Vim normal table and `Minga.Keymap.NormalPrefixes`, and every vim state of every built-in scope in `Minga.Keymap.Scope.Registry.builtin_modules/0`. `violations/2` classifies that inventory against the six grammar rules and returns one named violation per offending binding.

  `test/minga/keymap/grammar_test.exs` compares the violations with `test/fixtures/keymap/grammar_baseline.tsv`. The allow-lists below are the only sanctioned modifier conventions (rule 4), platform keys (rule 5) and CUA profile conventions (ADR-0007). Add to them only when the owner adopts a new convention, never to make a drifting binding pass.

  The CUA profile list exempts its desktop conventions from rules 4 and 5 only in a CUA vim state, and only for the command the convention names. Rule 6, one meaning per key, and the prompt rules still apply there.

  ## Rule ids

  * `:forbidden_chord`: three modifiers, two of ⌃ ⌥ ⌘ together, or a function key (rule 6).
  * `:platform_key`: a ⌘ chord that is not an allow-listed macOS platform key, or that does not alias a binding without modifiers (rule 5).
  * `:normal_mode_modifier`: a ⌃ or ⌥ chord where letters are not text: leader sequences, Vim buffers, special buffers (rule 4).
  * `:editing_collision`: a text-editing control key (⌃A ⌃E ⌃H ⌃W ⌃U ⌃K) bound where you type, other than list movement (rule 4).
  * `:unconventional_modifier`: any other ⌃ or ⌥ chord where you type that is not an established convention (rule 4).
  * `:text_key_binding`: a printable key bound where it must type text (rule 3).
  * `:vim_grammar_override`: a printable key rebound in a Vim normal state over a text field, where it must keep its Vim meaning (rule 2).
  * `:duplicate_key`: one key with two meanings in one scope and vim state, or a key that is both a command and a prefix.
  * `:duplicate_leader_command`: one command on two leader keys without a declared alias.
  * `:ungrouped_leader`: a leader binding outside a declared which-key group, or a top-level leader key that is not a Doom convention (rule 1).
  * `:doom_conflict`: a leader binding on a Doom key whose meaning is not declared in `doom_conventions.tsv`, or a declared row that no longer holds (rule 1).
  """

  import Bitwise

  alias Minga.Keymap.Defaults
  alias Minga.Keymap.NormalPrefixes
  alias Minga.Keymap.Scope.Registry, as: ScopeRegistry
  alias Minga.Keymap.SharedGroups

  @shift 0x01
  @ctrl 0x02
  @alt 0x04
  @cmd 0x08
  @chord_mods @ctrl ||| @alt ||| @cmd

  @space 32
  @enter 13

  @typedoc "A key tuple as stored in keymap tries: `{codepoint, modifiers}`."
  @type key :: {non_neg_integer(), non_neg_integer()}

  @typedoc "Where a binding lives: a built-in scope name or `:leader`."
  @type scope :: atom()

  @typedoc "One declared binding."
  @type binding :: %{
          scope: scope(),
          state: atom(),
          keys: [key()],
          command: term(),
          origin: :effective | {:shadowed_group, atom()}
        }

  @typedoc "One classified grammar violation."
  @type violation :: %{
          rule: atom(),
          scope: scope(),
          state: atom(),
          key: String.t(),
          command: String.t(),
          reason: String.t()
        }

  @typedoc "Identity of a violation: every column except the free-text reason."
  @type identity :: {String.t(), String.t(), String.t(), String.t(), String.t()}

  @typedoc "One row of `doom_conventions.tsv`."
  @type doom_row :: %{
          doom_key: String.t(),
          doom_meaning: String.t(),
          minga_key: String.t(),
          minga_command: String.t(),
          status: :matches | :diverges,
          reason: String.t()
        }

  @typedoc "How the grammar treats keys in a scope and vim state."
  @type context ::
          :leader
          | :vim_source
          | :vim_text
          | :special
          | :special_cua
          | :typing
          | :picker
          | :terminal

  # ── Contexts ────────────────────────────────────────────────────────────────
  #
  # Every {scope, vim state} that declares bindings must be classified here, so
  # a new scope or vim state cannot dodge the grammar by being unknown.
  #
  # * :leader      SPC sequences. Letters are mnemonics, never modifiers.
  # * :vim_source  The Vim normal table itself (rule 2's source of truth).
  # * :vim_text    A Vim normal state over a text field (the Agent composer):
  #                printable keys must keep their Vim meaning.
  # * :special     Special buffers (conversation navigation, file tree, git
  #                status): single mnemonic letters are allowed (rule 3).
  # * :special_cua The CUA model of a special buffer: letters act, and Vim's
  #                control keys carry no meaning.
  # * :typing      Letters type text (Agent composer insert, CUA surfaces).
  # * :picker      A live prompt (pickers, the minibuffer, the command line): typing edits the query. The prompt rules apply; the CUA profile never does.
  # * :terminal    TERMINAL mode in a terminal buffer: every key goes to the shell except ⌃\ ⌃N. No built-in scope declares it until the terminal ships (#4060).
  @contexts %{
    {:leader, :normal} => :leader,
    {:editor, :normal} => :vim_source,
    {:editor, :cua} => :typing,
    {:agent, :normal} => :special,
    {:agent, :insert} => :typing,
    {:agent, :input_normal} => :vim_text,
    {:agent, :cua} => :typing,
    {:file_tree, :normal} => :special,
    {:file_tree, :cua} => :special_cua,
    {:git_status, :normal} => :special,
    {:git_status, :cua} => :special_cua,
    {:picker, :insert} => :picker,
    {:prompt, :insert} => :picker
  }

  @scope_states [:normal, :insert, :input_normal, :cua]

  # Contexts a scope keymap is evaluated under.
  # The Agent scope adds a remedy binding while a failed start offers one, the picker adds ⌃V for sources whose selection shows in the focused window, and a prompt with a list adds list movement; other scopes ignore the context.
  @scope_contexts [[], [agent_start_remedy: :retry], [picker_split: true, prompt_list: true]]

  # ── Rule 4: established modifier conventions ───────────────────────────────
  #
  # {key, contexts it may appear in, allowed commands (or :any), why}.
  # ⌃T and ⌃Q document picker conventions whose features have not shipped (pins #4056, quickfix #4059); ⌃\ ⌃N waits for the terminal (#4060).
  @list_movement [:move_down, :move_up, :picker_next, :picker_prev, :prompt_next, :prompt_prev]

  @modifier_conventions [
    {{?j, @ctrl}, [:typing, :special, :special_cua, :vim_text, :vim_source, :picker],
     @list_movement, "⌃J moves down a list (Telescope, Vertico)"},
    {{?k, @ctrl}, [:typing, :special, :special_cua, :vim_text, :vim_source, :picker],
     @list_movement, "⌃K moves up a list (Telescope, Vertico)"},
    {{?v, @ctrl}, [:picker], :any, "⌃V opens the selection in a vertical split (Telescope)"},
    {{?t, @ctrl}, [:picker], :any, "⌃T opens or pins the selection (Telescope)"},
    {{?q, @ctrl}, [:picker], :any, "⌃Q sends the results to quickfix (Telescope)"},
    {{@enter, @alt}, [:typing], [:agent_queue_follow_up],
     "⌥↩ queues the next message in the composer"},
    {{?\\, @ctrl}, [:terminal], :any, "⌃\\ ⌃N leaves TERMINAL mode (Vim, Neovim)"},
    {{?n, @ctrl}, [:terminal], :any, "⌃\\ ⌃N leaves TERMINAL mode (Vim, Neovim)"},
    {{?., @ctrl},
     [:leader, :vim_source, :vim_text, :special, :special_cua, :typing, :picker, :terminal], :any,
     "⌃. opens the act menu (Embark)"}
  ]

  @doc "The rule 4 allow-list: `{key, contexts, allowed commands or :any, why}`."
  @spec modifier_conventions() :: [{key(), [context()], [term()] | :any, String.t()}]
  def modifier_conventions, do: @modifier_conventions

  @doc "The grammar context of a scope and vim state, or nil when it is unclassified."
  @spec context_for(scope(), atom()) :: context() | nil
  def context_for(scope, state), do: Map.get(@contexts, {scope, state})

  # Vim's own control keys are Vim grammar (rule 2), not added modifiers, in
  # Vim buffers and in special buffers that navigate like them. CUA states do
  # not get this allowance.
  @vim_ctrl_keys MapSet.new(~c"dufbeyroivaxw", &{&1, @ctrl})

  # Control keys that edit text in a prompt, insert mode or the composer
  # (readline and Emacs). Binding them there breaks typing.
  @editing_collisions MapSet.new(~c"aehwuk", &{&1, @ctrl})

  # ── Rule 5: macOS platform keys ─────────────────────────────────────────────
  #
  # Allowed only as aliases of a binding without modifiers that runs the same
  # command: ⌘S save, ⌘Z undo, ⌘W close, ⌘Q quit, ⌘. stop, ⌘1-⌘4 pinned files,
  # ⌘[ ⌘] back and forward.
  @platform_keys MapSet.new(~c"szwq.1234[]", &{&1, @cmd})

  # ── CUA profile (ADR-0007) ──────────────────────────────────────────────────
  #
  # {key, allowed commands, why}. In a CUA vim state these desktop conventions are exempt from rules 4 and 5 and may be the only binding for their action.
  # The exemption covers only the listed commands: ⌘C that opens a commit is not the copy convention. It never applies to live prompts (:picker), and rule 6 is checked first, so it cannot admit a forbidden chord.
  @cua_contexts [:typing, :special_cua]

  @cua_copy [:yank_visual_selection, :copy_or_interrupt, :agent_copy_code_block]
  @cua_cut [:delete_visual_selection]
  @cua_paste [:paste_after]
  @cua_undo [:undo]
  @cua_redo [:redo]
  @cua_select_all [:select_all]
  @cua_palette [:command_palette]
  @cua_newline [:agent_insert_newline]

  @cua_conventions [
    {{?c, @cmd}, @cua_copy, "⌘C copies (macOS)"},
    {{?v, @cmd}, @cua_paste, "⌘V pastes (macOS)"},
    {{?x, @cmd}, @cua_cut, "⌘X cuts (macOS)"},
    {{?z, @cmd}, @cua_undo, "⌘Z undoes (macOS)"},
    {{?z, @cmd ||| @shift}, @cua_redo, "⇧⌘Z redoes (macOS)"},
    {{?a, @cmd}, @cua_select_all, "⌘A selects all (macOS)"},
    {{?c, @ctrl}, @cua_copy, "⌃C copies (Linux, terminal)"},
    {{?v, @ctrl}, @cua_paste, "⌃V pastes (Linux, terminal)"},
    {{?x, @ctrl}, @cua_cut, "⌃X cuts (Linux, terminal)"},
    {{?z, @ctrl}, @cua_undo, "⌃Z undoes (Linux, terminal)"},
    {{?y, @ctrl}, @cua_redo, "⌃Y redoes (Linux, terminal)"},
    {{?a, @ctrl}, @cua_select_all, "⌃A selects all (Linux, terminal)"},
    {{?p, @ctrl}, @cua_palette, "⌃P opens the command palette"},
    {{?p, @ctrl ||| @shift}, @cua_palette, "⌃⇧P opens the command palette"},
    {{?P, @ctrl ||| @shift}, @cua_palette, "⌃⇧P opens the command palette"},
    {{?j, @ctrl}, @cua_newline, "⌃J adds a new line in the composer without sending"},
    {{@enter, @alt}, @cua_newline, "⌥↩ adds a new line in the composer without sending"}
  ]

  # ── Leader aliases ──────────────────────────────────────────────────────────
  #
  # {alias, canonical, why}. A command may sit on two leader keys only when one
  # is declared here as an alias of the other.
  @leader_aliases [
    {"SPC /", "SPC s p", "Doom binds both SPC / and SPC s p to project search"},
    {"SPC SPC", "SPC p f", "Doom binds both SPC SPC and SPC p f to find file in project"},
    {"SPC ,", "SPC b b", "Doom binds both SPC , and SPC b b to switch buffer"}
  ]

  # ── Normal mode aliases ─────────────────────────────────────────────────────
  #
  # {alias, canonical, why}. A ⌃ or ⌥ chord in a Vim buffer is allowed when it is declared here as an alias of a binding without modifiers that runs the same command, the way rule 5 allows platform keys.
  # docs/design/keys.md keeps ⌥h ⌥j ⌥k ⌥l only as aliases of the syntax-node keys.
  @normal_aliases [
    {"⌥h", "SPC c v", "⌥h expands the selection by syntax node, as SPC c v does"},
    {"⌥l", "SPC c V", "⌥l shrinks the selection by syntax node, as SPC c V does"},
    {"⌥j", "] n", "⌥j moves to the next syntax node, as ]n does"},
    {"⌥k", "[ n", "⌥k moves to the previous syntax node, as [n does"}
  ]

  # ── Key names ───────────────────────────────────────────────────────────────

  @named_keys %{
    9 => "TAB",
    10 => "LF",
    13 => "RET",
    27 => "ESC",
    32 => "SPC",
    127 => "DEL",
    0xF700 => "Up",
    0xF701 => "Down",
    0xF702 => "Left",
    0xF703 => "Right",
    57_350 => "Left(kitty)",
    57_351 => "Right(kitty)",
    57_352 => "Up(kitty)",
    57_353 => "Down(kitty)"
  }

  # ── Inventory ───────────────────────────────────────────────────────────────

  @doc "Every built-in binding: leader, Vim normal, and every built-in scope and vim state."
  @spec inventory() :: [binding()]
  def inventory do
    leader_bindings() ++ vim_normal_bindings() ++ scope_bindings()
  end

  @doc "Scope and vim state pairs in the inventory that have no grammar context."
  @spec unclassified([binding()]) :: [{scope(), atom()}]
  def unclassified(inventory) do
    inventory
    |> Enum.map(&{&1.scope, &1.state})
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(@contexts, &1))
    |> Enum.sort()
  end

  @spec leader_bindings() :: [binding()]
  defp leader_bindings do
    leader = Defaults.leader_key()
    filetype_prefix = [leader, {?m, 0}]

    declared =
      for {keys, command, _desc} <- Defaults.all_bindings() do
        effective(:leader, :normal, [leader | keys], command)
      end

    filetype =
      Defaults.filetype_bindings()
      |> Enum.map(fn {_ft, keys, command, _desc} -> {keys, command} end)
      |> Enum.uniq()
      |> Enum.map(fn {keys, command} ->
        effective(:leader, :normal, filetype_prefix ++ keys, command)
      end)

    declared ++ filetype
  end

  @spec vim_normal_bindings() :: [binding()]
  defp vim_normal_bindings do
    singles =
      for {key, {command, _desc}} <- Defaults.normal_bindings(),
          not prefix_marker?(command) do
        effective(:editor, :normal, [key], command)
      end

    prefixed =
      for {keys, command} <- walk(NormalPrefixes.trie()) do
        effective(:editor, :normal, keys, command)
      end

    singles ++ prefixed
  end

  # `Defaults.normal_bindings/0` lists `g` as `:prefix_g` for describe-key; the
  # sequences themselves live in `NormalPrefixes`.
  @spec prefix_marker?(term()) :: boolean()
  defp prefix_marker?(command) when is_atom(command),
    do: String.starts_with?(Atom.to_string(command), "prefix_")

  defp prefix_marker?(_command), do: false

  @spec scope_bindings() :: [binding()]
  defp scope_bindings do
    Enum.flat_map(ScopeRegistry.builtin_modules(), fn module ->
      scope = module.name()
      shared = walk(module.shared_keymap())

      Enum.flat_map(@scope_states, fn state ->
        effective =
          @scope_contexts
          |> Enum.flat_map(fn context -> walk(module.keymap(state, context)) end)
          |> Kernel.++(shared)
          |> Enum.uniq()
          |> Enum.map(fn {keys, command} -> effective(scope, state, keys, command) end)

        effective ++ shadowed_group_bindings(module, scope, state)
      end)
    end)
  end

  # A shared group binding that a scope rebinds to another command is a second
  # meaning for the key, even though the trie only keeps the last one. A group
  # counts as merged into a vim state when at least one of its bindings is
  # present there unchanged.
  @spec shadowed_group_bindings(module(), scope(), atom()) :: [binding()]
  defp shadowed_group_bindings(module, scope, state) do
    trie = Map.new(walk(module.keymap(state, [])))

    module
    |> included_group_names()
    |> Enum.flat_map(fn group ->
      bindings = SharedGroups.get(group)

      merged? =
        Enum.any?(bindings, fn {keys, command, _desc} -> Map.get(trie, keys) == command end)

      if merged? do
        for {keys, command, _desc} <- bindings,
            Map.get(trie, keys) not in [nil, command] do
          %{
            scope: scope,
            state: state,
            keys: keys,
            command: command,
            origin: {:shadowed_group, group}
          }
        end
      else
        []
      end
    end)
  end

  @spec included_group_names(module()) :: [atom()]
  defp included_group_names(module) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :included_groups, 0) do
      module.included_groups()
      |> Enum.map(fn
        {name, _opts} -> name
        name -> name
      end)
      |> Enum.uniq()
    else
      []
    end
  end

  @spec effective(scope(), atom(), [key()], term()) :: binding()
  defp effective(scope, state, keys, command),
    do: %{scope: scope, state: state, keys: keys, command: command, origin: :effective}

  @doc "Flattens a keymap trie into `{key_sequence, command}` pairs."
  @spec walk(Minga.Keymap.Bindings.node_t()) :: [{[key()], term()}]
  def walk(trie), do: walk(trie, [])

  @spec walk(Minga.Keymap.Bindings.node_t(), [key()]) :: [{[key()], term()}]
  defp walk(%{children: children}, path) do
    Enum.flat_map(children, fn {key, node} ->
      keys = path ++ [key]
      own = if node.command, do: [{keys, node.command}], else: []
      own ++ walk(node, keys)
    end)
  end

  # ── Classification ──────────────────────────────────────────────────────────

  @doc """
  Classifies an inventory against the grammar rules and the Doom conventions.

  `contexts` maps each `{scope, vim state}` to its grammar context and defaults to the built-in classification. Tests pass their own map to classify synthetic bindings, for example a live prompt that no built-in scope declares yet.
  """
  @spec violations([binding()], [doom_row()], %{{scope(), atom()} => context()}) :: [violation()]
  def violations(inventory, doom_rows, contexts \\ @contexts) do
    effective = Enum.filter(inventory, &(&1.origin == :effective))
    leader = Enum.filter(effective, &(&1.scope == :leader))

    (duplicate_keys(inventory) ++
       Enum.flat_map(effective, &binding_violations(&1, contexts)) ++
       ungrouped_leaders(leader, doom_rows) ++
       duplicate_leader_commands(leader) ++
       doom_conflicts(leader, doom_rows))
    |> Enum.uniq_by(&identity/1)
    |> Enum.sort_by(&identity/1)
  end

  @spec duplicate_keys([binding()]) :: [violation()]
  defp duplicate_keys(inventory) do
    by_context = Enum.group_by(inventory, &{&1.scope, &1.state})

    Enum.flat_map(by_context, fn {{scope, state}, bindings} ->
      two_meanings =
        bindings
        |> Enum.group_by(& &1.keys, & &1.command)
        |> Enum.flat_map(fn {keys, commands} ->
          case Enum.uniq(commands) do
            [_one] ->
              []

            many ->
              names = many |> Enum.map(&format_command/1) |> Enum.sort()

              [
                violation(
                  :duplicate_key,
                  scope,
                  state,
                  format_keys(keys),
                  Enum.join(names, " | "),
                  "#{length(names)} meanings for one key"
                )
              ]
          end
        end)

      all_keys = bindings |> Enum.map(& &1.keys) |> Enum.uniq()

      command_and_prefix =
        for %{keys: keys, command: command} <- bindings,
            Enum.any?(all_keys, &strict_prefix?(keys, &1)) do
          violation(
            :duplicate_key,
            scope,
            state,
            format_keys(keys),
            format_command(command),
            "bound as a command and as a prefix"
          )
        end

      two_meanings ++ command_and_prefix
    end)
  end

  @spec strict_prefix?([key()], [key()]) :: boolean()
  defp strict_prefix?(short, long),
    do: length(long) > length(short) and List.starts_with?(long, short)

  @spec binding_violations(binding(), %{{scope(), atom()} => context()}) :: [violation()]
  defp binding_violations(%{scope: scope, state: state, keys: keys, command: command}, contexts) do
    context = Map.get(contexts, {scope, state})

    case context && key_violation(keys, context, state, command) do
      nil ->
        []

      {rule, reason} ->
        [violation(rule, scope, state, format_keys(keys), format_command(command), reason)]
    end
  end

  # First failing key in the sequence wins, so each binding yields one row.
  @spec key_violation([key()], context(), atom(), term()) :: {atom(), String.t()} | nil
  defp key_violation(keys, context, state, command) do
    Enum.find_value(keys, fn key -> chord_violation(key, context, state, command) end) ||
      plain_key_violation(keys, context)
  end

  @spec chord_violation(key(), context(), atom(), term()) :: {atom(), String.t()} | nil
  defp chord_violation({codepoint, mods} = key, context, state, command) do
    cond do
      function_key?(codepoint) ->
        {:forbidden_chord, "function keys are never bound"}

      popcount(mods) >= 3 ->
        {:forbidden_chord, "three-modifier chord"}

      popcount(band(mods, @chord_mods)) >= 2 ->
        {:forbidden_chord, "combines two of ⌃ ⌥ ⌘"}

      cua_convention?(key, context, state, command) ->
        nil

      band(mods, @cmd) != 0 ->
        platform_violation(key, command)

      band(mods, @ctrl ||| @alt) != 0 ->
        modifier_violation(key, context, command)

      true ->
        nil
    end
  end

  @spec platform_violation(key(), term()) :: {atom(), String.t()} | nil
  defp platform_violation(key, command) do
    cond do
      not MapSet.member?(@platform_keys, key) ->
        {:platform_key, "not an allow-listed macOS platform key"}

      not MapSet.member?(plain_commands(), command) ->
        {:platform_key, "platform key without a binding that has no modifiers"}

      true ->
        nil
    end
  end

  # Commands reachable from some binding without ⌃ ⌥ ⌘, so a platform key can
  # alias them.
  @spec plain_commands() :: MapSet.t()
  defp plain_commands do
    for %{keys: keys, command: command} <- inventory(),
        Enum.all?(keys, fn {_cp, mods} -> band(mods, @chord_mods) == 0 end),
        into: MapSet.new(),
        do: command
  end

  @spec modifier_violation(key(), context(), term()) :: {atom(), String.t()} | nil
  defp modifier_violation(key, context, command) do
    cond do
      convention?(key, context, command) ->
        nil

      context == :vim_source and declared_normal_alias?(key, command) ->
        nil

      context in [:vim_source, :vim_text, :special] and MapSet.member?(@vim_ctrl_keys, key) ->
        nil

      context in [:typing, :picker] and MapSet.member?(@editing_collisions, key) ->
        {:editing_collision, "text-editing control key where you type"}

      context in [:typing, :picker] ->
        {:unconventional_modifier, "modifier where you type is not an established convention"}

      true ->
        {:normal_mode_modifier, "modifier where letters are not text"}
    end
  end

  # A declared alias passes only while its canonical keys run the same command.
  @spec declared_normal_alias?(key(), term()) :: boolean()
  defp declared_normal_alias?(key, command) do
    formatted = format_key(key)

    Enum.any?(@normal_aliases, fn {alias_key, canonical, _why} ->
      alias_key == formatted and Map.get(plain_bindings(), canonical) == command
    end)
  end

  # Leader and Vim normal bindings without ⌃ ⌥ ⌘, keyed by their formatted keys.
  @spec plain_bindings() :: %{String.t() => term()}
  defp plain_bindings do
    for %{scope: scope, keys: keys, command: command} <- inventory(),
        scope in [:leader, :editor],
        Enum.all?(keys, fn {_cp, mods} -> band(mods, @chord_mods) == 0 end),
        into: %{},
        do: {format_keys(keys), command}
  end

  @spec convention?(key(), context(), term()) :: boolean()
  defp convention?(key, context, command) do
    Enum.any?(@modifier_conventions, fn {conv_key, contexts, commands, _why} ->
      conv_key == key and context in contexts and (commands == :any or command in commands)
    end)
  end

  @spec cua_convention?(key(), context(), atom(), term()) :: boolean()
  defp cua_convention?(key, context, :cua, command) when context in @cua_contexts do
    Enum.any?(@cua_conventions, fn {conv_key, commands, _why} ->
      conv_key == key and command in commands
    end)
  end

  defp cua_convention?(_key, _context, _state, _command), do: false

  @spec plain_key_violation([key()], context()) :: {atom(), String.t()} | nil
  defp plain_key_violation([{codepoint, mods} | _], :typing)
       when band(mods, @chord_mods) == 0 do
    if printable?(codepoint),
      do: {:text_key_binding, "printable key where it types text"},
      else: nil
  end

  defp plain_key_violation([{codepoint, mods} | _], :vim_text)
       when band(mods, @chord_mods) == 0 do
    if printable?(codepoint),
      do: {:vim_grammar_override, "printable key rebound over Vim grammar in a text field"},
      else: nil
  end

  defp plain_key_violation(_keys, _context), do: nil

  @spec printable?(non_neg_integer()) :: boolean()
  defp printable?(codepoint),
    do: codepoint >= @space and codepoint != 127 and codepoint < 0xE000

  @spec function_key?(non_neg_integer()) :: boolean()
  defp function_key?(codepoint),
    do: codepoint in 0xF704..0xF726 or codepoint in 57_364..57_398

  @spec popcount(non_neg_integer()) :: non_neg_integer()
  defp popcount(mods),
    do: Enum.count([@shift, @ctrl, @alt, @cmd], &(band(mods, &1) != 0))

  # ── Leader rules ────────────────────────────────────────────────────────────

  @spec ungrouped_leaders([binding()], [doom_row()]) :: [violation()]
  defp ungrouped_leaders(leader, doom_rows) do
    groups = declared_groups()
    doom_keys = MapSet.new(doom_rows, & &1.doom_key)

    Enum.flat_map(leader, fn %{keys: [_leader | rest]} = binding ->
      key = format_keys(binding.keys)

      missing =
        Enum.find(1..(length(rest) - 1)//1, fn n ->
          not MapSet.member?(groups, Enum.take(rest, n))
        end)

      cond do
        length(rest) == 1 and not MapSet.member?(doom_keys, key) ->
          [
            violation(
              :ungrouped_leader,
              :leader,
              :normal,
              key,
              format_command(binding.command),
              "top-level leader key that is not a Doom convention"
            )
          ]

        missing ->
          group = format_keys([Defaults.leader_key() | Enum.take(rest, missing)])

          [
            violation(
              :ungrouped_leader,
              :leader,
              :normal,
              key,
              format_command(binding.command),
              "#{group} is not a declared which-key group"
            )
          ]

        true ->
          []
      end
    end)
  end

  @spec declared_groups() :: MapSet.t()
  defp declared_groups do
    filetype = for {keys, _label} <- Defaults.filetype_group_prefixes(), do: [{?m, 0} | keys]
    leader = for {keys, _label} <- Defaults.group_prefixes(), do: keys
    MapSet.new(leader ++ filetype)
  end

  @spec duplicate_leader_commands([binding()]) :: [violation()]
  defp duplicate_leader_commands(leader) do
    aliases =
      MapSet.new(@leader_aliases, fn {alias_key, canonical, _why} -> {alias_key, canonical} end)

    leader
    |> Enum.group_by(& &1.command, &format_keys(&1.keys))
    |> Enum.flat_map(fn {command, keys} ->
      keys = Enum.uniq(keys)

      undeclared =
        Enum.reject(keys, fn key ->
          Enum.any?(keys, &MapSet.member?(aliases, {key, &1}))
        end)

      case Enum.sort(undeclared) do
        [_ | [_ | _]] = sorted ->
          [
            violation(
              :duplicate_leader_command,
              :leader,
              :normal,
              Enum.join(sorted, ", "),
              format_command(command),
              "one command on #{length(sorted)} leader keys without a declared alias"
            )
          ]

        _one_or_none ->
          []
      end
    end)
  end

  @spec doom_conflicts([binding()], [doom_row()]) :: [violation()]
  defp doom_conflicts(leader, doom_rows) do
    bound = Map.new(leader, &{format_keys(&1.keys), format_command(&1.command)})
    declared = MapSet.new(doom_rows, &{&1.minga_key, &1.minga_command})

    stale =
      for %{minga_key: key, minga_command: command} = row <- doom_rows,
          key != "-",
          Map.get(bound, key) != command do
        violation(
          :doom_conflict,
          :leader,
          :normal,
          key,
          Map.get(bound, key, "unbound"),
          "doom_conventions.tsv expects #{command} (Doom #{row.doom_key}: #{row.doom_meaning})"
        )
      end

    undeclared =
      for %{doom_key: doom_key, doom_meaning: meaning} <- doom_rows,
          command = Map.get(bound, doom_key),
          command != nil,
          not MapSet.member?(declared, {doom_key, command}) do
        violation(
          :doom_conflict,
          :leader,
          :normal,
          doom_key,
          command,
          "Doom binds #{doom_key} to #{meaning}; declare matches or diverges"
        )
      end

    stale ++ undeclared
  end

  # ── Formatting ──────────────────────────────────────────────────────────────

  @doc "Formats a key sequence with Mac modifier glyphs, for example `SPC f f` or `⌃j`."
  @spec format_keys([key()]) :: String.t()
  def format_keys(keys), do: Enum.map_join(keys, " ", &format_key/1)

  @spec format_key(key()) :: String.t()
  defp format_key({codepoint, mods}), do: glyphs(mods) <> key_name(codepoint)

  @spec glyphs(non_neg_integer()) :: String.t()
  defp glyphs(mods) do
    [{@ctrl, "⌃"}, {@alt, "⌥"}, {@shift, "⇧"}, {@cmd, "⌘"}]
    |> Enum.filter(fn {bit, _glyph} -> band(mods, bit) != 0 end)
    |> Enum.map_join(fn {_bit, glyph} -> glyph end)
  end

  @spec key_name(non_neg_integer()) :: String.t()
  defp key_name(codepoint) when is_map_key(@named_keys, codepoint),
    do: Map.fetch!(@named_keys, codepoint)

  defp key_name(codepoint) when codepoint in 0xF704..0xF726, do: "F#{codepoint - 0xF703}"
  defp key_name(codepoint) when codepoint in 57_364..57_398, do: "F#{codepoint - 57_363}(kitty)"

  defp key_name(codepoint) when codepoint > @space and codepoint < 0xE000,
    do: <<codepoint::utf8>>

  defp key_name(codepoint), do: "U+" <> Integer.to_string(codepoint, 16)

  @spec format_command(term()) :: String.t()
  defp format_command(command) when is_atom(command), do: Atom.to_string(command)
  defp format_command(command), do: inspect(command)

  @spec violation(atom(), scope(), atom(), String.t(), String.t(), String.t()) :: violation()
  defp violation(rule, scope, state, key, command, reason),
    do: %{rule: rule, scope: scope, state: state, key: key, command: command, reason: reason}

  # ── Fixtures ────────────────────────────────────────────────────────────────

  @doc "The identity of a violation or baseline row: every column except the reason."
  @spec identity(violation()) :: identity()
  def identity(%{rule: rule, scope: scope, state: state, key: key, command: command}),
    do: {to_string(rule), to_string(scope), to_string(state), key, command}

  @doc "Reads a TSV fixture, skipping `#` comment lines and blank lines."
  @spec read_tsv(Path.t()) :: [[String.t()]]
  def read_tsv(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&String.split(&1, "\t"))
  end

  @doc "Reads `grammar_baseline.tsv` into violations."
  @spec read_baseline(Path.t()) :: [violation()]
  def read_baseline(path) do
    for [rule, scope, state, key, command, reason] <- read_tsv(path) do
      %{
        rule: String.to_atom(rule),
        scope: String.to_atom(scope),
        state: String.to_atom(state),
        key: key,
        command: command,
        reason: reason
      }
    end
  end

  @doc "Reads `doom_conventions.tsv`. Raises on a malformed row."
  @spec read_doom(Path.t()) :: [doom_row()]
  def read_doom(path) do
    for row <- read_tsv(path) do
      case row do
        [doom_key, meaning, minga_key, minga_command, status, reason]
        when status in ["matches", "diverges"] ->
          %{
            doom_key: doom_key,
            doom_meaning: meaning,
            minga_key: minga_key,
            minga_command: minga_command,
            status: doom_status(status),
            reason: reason
          }

        other ->
          raise ArgumentError, "malformed doom_conventions.tsv row: #{inspect(other)}"
      end
    end
  end

  @spec doom_status(String.t()) :: :matches | :diverges
  defp doom_status("matches"), do: :matches
  defp doom_status("diverges"), do: :diverges

  @baseline_header """
  # Key grammar baseline: violations that existed when the guard landed.
  #
  # Entries may only be removed, never added. The migration tickets remove them.
  # A new binding that breaks the grammar must follow the grammar instead; see
  # AGENTS.md "Key grammar" and test/minga/keymap/grammar_test.exs.
  #
  # Regenerate only to prune rows the code no longer violates:
  #   MINGA_WRITE_KEY_GRAMMAR_BASELINE=1 mix test test/minga/keymap/grammar_test.exs
  # The writer keeps only rows that are already in this file, so it cannot add one.
  #
  # rule\tscope\tvim_state\tkey\tcommand\treason
  """

  @doc """
  Writes the baseline. With no existing file it records every current violation; otherwise it keeps only existing rows that still apply, so it can remove rows but never add one.
  """
  @spec write_baseline!(Path.t(), [violation()]) :: :ok
  def write_baseline!(path, violations) do
    rows =
      if File.exists?(path) do
        kept = MapSet.new(read_baseline(path), &identity/1)
        Enum.filter(violations, &MapSet.member?(kept, identity(&1)))
      else
        violations
      end

    body =
      rows
      |> Enum.sort_by(&identity/1)
      |> Enum.map_join(fn v ->
        Enum.join([v.rule, v.scope, v.state, v.key, v.command, v.reason], "\t") <> "\n"
      end)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @baseline_header <> body)
  end
end
