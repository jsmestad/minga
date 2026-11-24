defmodule Minga.Keymap.Scope.Picker do
  @moduledoc """
  Keymap scope for pickers: find file, project search, the buffer switcher and every other list with a query.

  Typing edits the query, so the scope binds only the established picker conventions (`docs/design/keys.md`): `⌃J` / `⌃K` and the arrows move, `↩` opens the selection, `esc` closes, `Tab` completes, `PageUp` / `PageDown` page, `⌃.` opens the act menu on the highlighted row, and `⌃V` opens a location in a vertical split. The tries come from `Minga.Keymap.PromptKeys`.

  Pickers always take text, so only the `:insert` vim state has bindings; the CUA profile never applies to a live prompt. `MingaEditor.PickerUI` resolves keys here before it edits the query, and passes `picker_split: true` in the context when the source opens a location.
  """

  use Minga.Keymap.Scope.Builder,
    name: :picker,
    display_name: "Picker",
    modal: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.PromptKeys

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(:insert, context),
    do: PromptKeys.picker_trie(split: Keyword.get(context, :picker_split, false))

  def keymap(_vim_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec help_groups(atom()) :: [Minga.Keymap.Scope.help_group()]
  def help_groups(_focus) do
    [
      {"Picker",
       [
         {"⌃J / ⌃K", "Move down / up"},
         {"↩", "Open the selection"},
         {"⌃V", "Open in a split"},
         {"⌃.", "Act on the highlighted row"},
         {"Tab", "Complete"},
         {"esc", "Close"}
       ]}
    ]
  end
end
