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

  use Minga.Keymap.Scope.Builder,
    name: :file_tree,
    display_name: "File Tree"

  alias Minga.Keymap.Bindings

  @tab 9
  @enter 13
  @escape 27

  # Groups included by this scope, per vim state.
  # CUA mode gets arrow-key navigation from the shared group.
  @cua_groups [:cua_navigation]

  @impl true
  @spec included_groups() :: [atom() | {atom(), keyword()}]
  def included_groups, do: @cua_groups

  # ── Keymap ─────────────────────────────────────────────────────────────────

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(:normal, _context), do: normal_trie()
  def keymap(:cua, _context), do: cua_trie()
  def keymap(_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec help_groups(atom()) :: [Minga.Keymap.Scope.help_group()]
  def help_groups(_focus) do
    [
      {"Navigation",
       [
         {"j / k", "Move cursor down / up"},
         {"gg / G", "Jump to top / bottom"},
         {"Ctrl-d / Ctrl-u", "Half page down / up"}
       ]},
      {"Tree",
       [
         {"Enter", "Open file / toggle directory"},
         {"Tab", "Toggle directory expand"},
         {"l / h", "Expand / collapse directory"},
         {"H", "Toggle hidden files"},
         {"r", "Refresh tree"}
       ]},
      {"File Operations",
       [
         {"a", "New file"},
         {"A", "New folder"},
         {"R", "Rename"}
       ]},
      {"View",
       [
         {"q / Esc", "Close file tree"}
       ]}
    ]
  end

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
    |> Bindings.bind([{?a, 0}], :tree_new_file, "New file")
    |> Bindings.bind([{?A, 0}], :tree_new_folder, "New folder")
    |> Bindings.bind([{?R, 0}], :tree_rename, "Rename")
  end

  # ── CUA mode bindings ─────────────────────────────────────────────────────
  # Arrow keys for navigation, Enter to open, Escape to close.
  # Left/Right expand/collapse directories (matching macOS Finder).

  @spec cua_trie() :: Bindings.node_t()
  defp cua_trie do
    build_trie(
      groups: @cua_groups,
      then: fn trie ->
        trie
        |> Bindings.bind([{@enter, 0}], :tree_open_or_toggle, "Open file / toggle directory")
        |> Bindings.bind([{@escape, 0}], :tree_close, "Close file tree")
        # Arrow left/right: collapse/expand (Finder-style)
        |> Bindings.bind([{57_351, 0}], :tree_expand, "Expand directory")
        |> Bindings.bind([{57_350, 0}], :tree_collapse, "Collapse directory")
        |> Bindings.bind([{0xF703, 0}], :tree_expand, "Expand directory")
        |> Bindings.bind([{0xF702, 0}], :tree_collapse, "Collapse directory")
      end
    )
  end
end
