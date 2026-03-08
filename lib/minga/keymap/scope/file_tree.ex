defmodule Minga.Keymap.Scope.FileTree do
  @moduledoc """
  Keymap scope for the file tree panel.

  Provides tree navigation and manipulation bindings: Enter to open files,
  h/l to collapse/expand directories, H to toggle hidden files, r to refresh.
  Unmatched keys fall through to the global leader trie and Mode.process
  (for vim navigation like j/k/gg/G/Ctrl-d/Ctrl-u).

  The file tree always operates in normal mode. Mode transitions to insert
  or visual are blocked.
  """

  @behaviour Minga.Keymap.Scope

  alias Minga.Keymap.Bindings

  @tab 9
  @enter 13
  @escape 27

  # ── Behaviour callbacks ────────────────────────────────────────────────────

  @impl true
  @spec name() :: :file_tree
  def name, do: :file_tree

  @impl true
  @spec display_name() :: String.t()
  def display_name, do: "File Tree"

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(:normal, _context), do: normal_trie()
  def keymap(_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec on_enter(term()) :: term()
  def on_enter(state), do: state

  @impl true
  @spec on_exit(term()) :: term()
  def on_exit(state), do: state

  # ── Normal mode bindings ───────────────────────────────────────────────────

  @spec normal_trie() :: Bindings.node_t()
  defp normal_trie do
    Bindings.new()
    |> Bindings.bind([{@enter, 0}], :tree_open_or_toggle, "Open file / toggle directory")
    |> Bindings.bind([{@tab, 0}], :tree_toggle_directory, "Toggle directory")
    |> Bindings.bind([{?l, 0}], :tree_expand, "Expand directory")
    |> Bindings.bind([{?h, 0}], :tree_collapse, "Collapse directory")
    |> Bindings.bind([{?H, 0}], :tree_toggle_hidden, "Toggle hidden files")
    |> Bindings.bind([{?r, 0}], :tree_refresh, "Refresh file tree")
    |> Bindings.bind([{?q, 0}], :tree_close, "Close file tree")
    |> Bindings.bind([{@escape, 0}], :tree_close, "Close file tree")
  end
end
