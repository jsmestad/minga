defmodule Minga.Keymap.Scope.Prompt do
  @moduledoc """
  Keymap scope for minibuffer prompts and the `:` command line.

  Typing edits the text, so the scope binds only `↩` (run), `esc` (cancel) and `Tab` (complete), plus `⌃J` / `⌃K` and the arrows when the prompt shows a list (the command line's completions). Readline keys (`⌃A`, `⌃E`, `⌃H`, `⌃W`, `⌃U`, and `⌃K` without a list) stay text editing through `Minga.Editing.LineEdit`. The tries come from `Minga.Keymap.PromptKeys`.

  Prompts always take text, so only the `:insert` vim state has bindings. `MingaEditor.PromptUI` resolves keys here, so user overrides for `{:prompt, :insert}` apply to minibuffer prompts. The `:` command line is a pure mode (`Minga.Mode.Command`) and reads the default trie from `Minga.Keymap.PromptKeys` with a list directly, so overrides do not reach it.
  """

  use Minga.Keymap.Scope.Builder,
    name: :prompt,
    display_name: "Prompt",
    modal: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.PromptKeys

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(:insert, context),
    do: PromptKeys.prompt_trie(list: Keyword.get(context, :prompt_list, false))

  def keymap(_vim_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec help_groups(atom()) :: [Minga.Keymap.Scope.help_group()]
  def help_groups(_focus) do
    [
      {"Prompt",
       [
         {"↩", "Run"},
         {"⌃J / ⌃K", "Move through the list, when there is one"},
         {"Tab", "Complete"},
         {"esc", "Cancel"}
       ]}
    ]
  end
end
