defmodule Minga.Keymap.PromptKeys do
  @moduledoc """
  The keys of live prompts: pickers, minibuffer prompts and the `:` command line.

  While a prompt has focus, typing always edits the query, so the only bindings are the established list and picker conventions from `docs/design/keys.md`: `⌃J` / `⌃K` and the arrows move through the list, `↩` runs the selection, `esc` closes, `Tab` completes, and pickers add `⌃V` (open in a split, for the buffer switcher) and `⌃.` (act menu on the highlighted row). Everything else is text editing, owned by the field: printable keys insert, and `⌃A`, `⌃E`, `⌃H`, `⌃W`, `⌃U` and `⌃K` (where `⌃K` is not list movement) edit the line through `Minga.Editing.LineEdit`.

  The tries are pure data so the `:` command line (`Minga.Mode.Command`) can resolve them directly. `Minga.Keymap.Scope.Picker` and `Minga.Keymap.Scope.Prompt` publish the same tries as keymap scopes, which is how which-key, user overrides and the key-grammar guard see them.
  """

  alias Minga.Keymap.Bindings

  import Bitwise, only: [band: 2]

  @shift 0x01
  @ctrl 0x02
  @alt 0x04
  @super 0x08

  @enter 13
  @escape 27
  @tab 9

  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_up_mac 0xF700
  @arrow_down_mac 0xF701
  @page_up 57_362
  @page_down 57_363

  @typedoc "Context for the minibuffer prompt trie."
  @type prompt_option :: {:list, boolean()}

  @typedoc "Context for the picker trie."
  @type picker_option :: {:split, boolean()}

  @list_movement [
    {[{?j, @ctrl}], :next, "Next"},
    {[{@arrow_down, 0}], :next, "Next"},
    {[{@arrow_down_mac, 0}], :next, "Next"},
    {[{?k, @ctrl}], :prev, "Previous"},
    {[{@arrow_up, 0}], :prev, "Previous"},
    {[{@arrow_up_mac, 0}], :prev, "Previous"}
  ]

  @picker_bindings [
    {[{@enter, 0}], :picker_select, "Open the selection"},
    {[{@escape, 0}], :picker_cancel, "Close"},
    {[{@tab, 0}], :picker_complete, "Complete"},
    {[{@page_down, 0}], :picker_page_down, "Page down"},
    {[{@page_up, 0}], :picker_page_up, "Page up"},
    {[{?., @ctrl}], :picker_act_menu, "Act on the highlighted row"}
  ]

  @picker_split {[{?v, @ctrl}], :picker_open_split, "Open in a split"}

  # A picker with nothing to filter takes no text, so it is a list: its letters act, as in a special buffer.
  @picker_list_bindings [
    {[{@enter, 0}], :picker_select, "Run the selection"},
    {[{@escape, 0}], :picker_cancel, "Close"},
    {[{?q, 0}], :picker_cancel, "Close"},
    {[{?j, 0}], :picker_next, "Next"},
    {[{?k, 0}], :picker_prev, "Previous"}
  ]

  @prompt_bindings [
    {[{@enter, 0}], :prompt_submit, "Run"},
    {[{@escape, 0}], :prompt_cancel, "Cancel"},
    {[{@tab, 0}], :prompt_complete, "Complete"}
  ]

  # The tries are built once, at compile time: these lookups run on every keystroke in a prompt.
  build = fn bindings ->
    Enum.reduce(bindings, Bindings.new(), fn {keys, command, desc}, trie ->
      Bindings.bind(trie, keys, command, desc)
    end)
  end

  list_movement = fn next, prev ->
    Enum.map(@list_movement, fn
      {keys, :next, desc} -> {keys, next, desc}
      {keys, :prev, desc} -> {keys, prev, desc}
    end)
  end

  @picker_trie build.(@picker_bindings ++ list_movement.(:picker_next, :picker_prev))
  @picker_split_trie build.([
                       @picker_split
                       | @picker_bindings ++ list_movement.(:picker_next, :picker_prev)
                     ])
  @picker_list_trie build.(@picker_list_bindings ++ list_movement.(:picker_next, :picker_prev))
  @prompt_trie build.(@prompt_bindings)
  @prompt_list_trie build.(@prompt_bindings ++ list_movement.(:prompt_next, :prompt_prev))

  @doc """
  Returns the picker trie.

  Pass `split: true` when the picker's source shows its selection in the focused window (the buffer switcher), so `⌃V` can open the selection in a vertical split.
  """
  @spec picker_trie([picker_option()]) :: Bindings.node_t()
  def picker_trie(opts \\ []) do
    if Keyword.get(opts, :split, false), do: @picker_split_trie, else: @picker_trie
  end

  @doc """
  Returns the trie of a picker with nothing to filter: no candidates, so it offers only its next steps (`MingaEditor.UI.Picker.Empty`).

  Nothing is typed there, so the list keys of a special buffer apply: `j` / `k` (and `⌃J` / `⌃K`, the arrows) move, `↩` runs the selected step, `q` and `esc` close.
  """
  @spec picker_list_trie() :: Bindings.node_t()
  def picker_list_trie, do: @picker_list_trie

  @hint_commands [
    {[:picker_next, :picker_prev], "move"},
    {[:picker_select], "run"},
    {[:picker_cancel], "close"}
  ]

  @doc """
  The footer hints of an empty picker: the keys that move, run and close, labelled for display, as `{keys, word}` pairs.

  The hints follow what the list can do: with next-step rows (`rows?`) it can move, run and close; with no rows only close is offered, since there is nothing to move to or run.

  `keys_for` returns the single keys that run a command in the picker scope as it resolves keys now, user overrides included (`MingaEditor.State.Picker.keys_for_command/3`), so the footer names keys that do what it says, and a rebind shows. A list with nothing to type (`list_keys?`) prefers plain letters (`j k`, `q`); a prompt prefers control keys (`⌃J ⌃K`) and named keys (`↩`, `esc`).
  """
  @spec picker_hints(boolean(), boolean(), (atom() -> [Bindings.key()])) :: [
          {String.t(), String.t()}
        ]
  def picker_hints(rows?, list_keys?, keys_for)
      when is_boolean(rows?) and is_boolean(list_keys?) and is_function(keys_for, 1) do
    offered =
      if rows?, do: @hint_commands, else: Enum.filter(@hint_commands, &match?({_, "close"}, &1))

    for {commands, word} <- offered,
        keys = Enum.map(commands, &hint_key(keys_for.(&1), list_keys?)),
        Enum.all?(keys),
        do: {Enum.join(keys, " "), word}
  end

  @spec hint_key([Bindings.key()], boolean()) :: String.t() | nil
  defp hint_key(keys, list_keys?) do
    keys
    |> Enum.min_by(&{hint_rank(&1, list_keys?), &1}, fn -> nil end)
    |> hint_label()
  end

  # Lower ranks are shown first: plain letters in a list, control keys in a prompt, then named keys, then arrows,
  # then keys held with other modifiers.
  @spec hint_rank(Bindings.key(), boolean()) :: non_neg_integer()
  defp hint_rank({cp, 0}, true) when cp in ?!..?~, do: 0
  defp hint_rank({_cp, @ctrl}, _list_keys?), do: 1
  defp hint_rank({cp, 0}, _list_keys?) when cp in [@enter, @escape, @tab], do: 2
  defp hint_rank({_cp, 0}, _list_keys?), do: 3
  defp hint_rank(_key, _list_keys?), do: 4

  # Every modifier is named, so a key held with ⌥ or ⌘ never reads as the plain key, which would type in a prompt.
  @spec hint_label(Bindings.key() | nil) :: String.t() | nil
  defp hint_label(nil), do: nil
  defp hint_label({cp, mods}), do: modifier_label(mods) <> key_label(cp, mods)

  @spec modifier_label(non_neg_integer()) :: String.t()
  defp modifier_label(mods) do
    for {bit, glyph} <- [{@ctrl, "⌃"}, {@alt, "⌥"}, {@shift, "⇧"}, {@super, "⌘"}],
        band(mods, bit) != 0,
        into: "",
        do: glyph
  end

  @spec key_label(non_neg_integer(), non_neg_integer()) :: String.t()
  defp key_label(@enter, _mods), do: "↩"
  defp key_label(@escape, _mods), do: "esc"
  defp key_label(@tab, _mods), do: "Tab"
  defp key_label(cp, _mods) when cp in [@arrow_down, @arrow_down_mac], do: "↓"
  defp key_label(cp, _mods) when cp in [@arrow_up, @arrow_up_mac], do: "↑"
  defp key_label(cp, 0), do: <<cp::utf8>>
  defp key_label(cp, _mods), do: String.upcase(<<cp::utf8>>)

  @doc """
  Returns the minibuffer prompt trie.

  Pass `list: true` when the prompt shows a list (the command line's completions), so `⌃J` / `⌃K` and the arrows move through it. A prompt without a list leaves `⌃K` to text editing.
  """
  @spec prompt_trie([prompt_option()]) :: Bindings.node_t()
  def prompt_trie(opts \\ []) do
    if Keyword.get(opts, :list, false), do: @prompt_list_trie, else: @prompt_trie
  end
end
