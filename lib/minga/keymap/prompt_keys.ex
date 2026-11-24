defmodule Minga.Keymap.PromptKeys do
  @moduledoc """
  The keys of live prompts: pickers, minibuffer prompts and the `:` command line.

  While a prompt has focus, typing always edits the query, so the only bindings are the established list and picker conventions from `docs/design/keys.md`: `⌃J` / `⌃K` and the arrows move through the list, `↩` runs the selection, `esc` closes, `Tab` completes, and pickers add `⌃V` (open in a split) and `⌃.` (act menu on the highlighted row). Everything else is text editing, owned by the field: printable keys insert, and `⌃A`, `⌃E`, `⌃H`, `⌃W`, `⌃U` and `⌃K` (where `⌃K` is not list movement) edit the line through `Minga.Editing.LineEdit`.

  The tries are pure data so the `:` command line (`Minga.Mode.Command`) can resolve them directly. `Minga.Keymap.Scope.Picker` and `Minga.Keymap.Scope.Prompt` publish the same tries as keymap scopes, which is how which-key, user overrides and the key-grammar guard see them.
  """

  alias Minga.Keymap.Bindings

  @ctrl 0x02

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
  @prompt_trie build.(@prompt_bindings)
  @prompt_list_trie build.(@prompt_bindings ++ list_movement.(:prompt_next, :prompt_prev))

  @doc """
  Returns the picker trie.

  Pass `split: true` when the picker's source opens a location, so `⌃V` can open the selection in a vertical split.
  """
  @spec picker_trie([picker_option()]) :: Bindings.node_t()
  def picker_trie(opts \\ []) do
    if Keyword.get(opts, :split, false), do: @picker_split_trie, else: @picker_trie
  end

  @doc """
  Returns the minibuffer prompt trie.

  Pass `list: true` when the prompt shows a list (the command line's completions), so `⌃J` / `⌃K` and the arrows move through it. A prompt without a list leaves `⌃K` to text editing.
  """
  @spec prompt_trie([prompt_option()]) :: Bindings.node_t()
  def prompt_trie(opts \\ []) do
    if Keyword.get(opts, :list, false), do: @prompt_list_trie, else: @prompt_trie
  end
end
