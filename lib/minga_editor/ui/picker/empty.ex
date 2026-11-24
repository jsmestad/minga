defmodule MingaEditor.UI.Picker.Empty do
  @moduledoc """
  What a picker source offers when nothing matches: a header that says what happened and why, and the next steps as result rows.

  A source returns one from its optional `empty/1` callback (`MingaEditor.UI.Picker.Source`). The picker offers the rows in place of results, so they are reached with `⌃J` / `⌃K` or the arrows, run with `↩` and clicked like any row; typing keeps editing the query. Selecting a row calls the source's `on_select/2` with an item whose id is `{:next_step, step}`.

  Row keys are resolved from the live keymap (`Minga.Keymap.Active.leader_key/2`), so a row never teaches a key the user has rebound.

  `typing?` says whether typing still means something. A source with no candidates at all sets it to `false`: there is nothing to filter, so the picker becomes a list (`j` / `k` move, `↩` runs, `q` closes; see `Minga.Keymap.Scope.Picker`).
  """

  alias Minga.Keymap.Active
  alias MingaEditor.UI.Picker.Item

  @typedoc "What the source knows when nothing matches: the query, how many candidates it had, and the context it was opened with."
  @type request :: %{query: String.t(), total: non_neg_integer(), context: term()}

  @type t :: %__MODULE__{
          glyph: String.t(),
          title: String.t(),
          why: String.t(),
          rows: [Item.t()],
          typing?: boolean()
        }

  @enforce_keys [:title, :rows]
  defstruct glyph: "", title: "", why: "", rows: [], typing?: true

  @doc "A next-step row: `step` comes back in the item id on selection, `key` is shown beside the label."
  @spec row(term(), String.t(), String.t()) :: Item.t()
  def row(step, label, key) when is_binary(label) and is_binary(key),
    do: %Item{id: {:next_step, step}, label: label, annotation: key}

  @doc "A next-step row that runs a leader command, labelled with the key the live keymap binds it to."
  @spec command_row(atom(), String.t()) :: Item.t()
  def command_row(command, label) when is_atom(command) and is_binary(label),
    do: row({:command, command}, label, Active.leader_key(command))

  @doc "Runs a `command_row/2` after the picker closes, the way the command palette does."
  @spec run_command(Item.t(), state) :: state when state: map()
  def run_command(%Item{id: {:next_step, {:command, command}}}, state) when is_atom(command),
    do: Map.put(state, :pending_command, command)

  @doc "True for an item that is a next-step row rather than a result."
  @spec next_step?(Item.t()) :: boolean()
  def next_step?(%Item{id: {:next_step, _step}}), do: true
  def next_step?(%Item{}), do: false

  @doc "Quotes a query for a title, such as `“limit_lable”`."
  @spec quoted(String.t()) :: String.t()
  def quoted(query) when is_binary(query), do: "“" <> query <> "”"
end
