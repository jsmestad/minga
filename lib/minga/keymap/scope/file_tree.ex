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

  import Minga.Keymap.Sigil

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
         {"r", "Refresh tree"},
         {"- / . / ~", "Parent root / selected root / project root"}
       ]},
      {"File Operations",
       [
         {"a", "New file"},
         {"A", "New folder"},
         {"R", "Rename"},
         {"d", "Delete"},
         {"y", "Copy path"},
         {"c / m", "Mark copy / move"},
         {"p", "Paste marked entry"}
       ]},
      {"View",
       [
         {"/", "Filter tree"},
         {"?", "Toggle help"},
         {"q / Esc", "Close file tree"}
       ]}
    ]
  end

  # ── Normal mode bindings ───────────────────────────────────────────────────

  @spec normal_trie() :: Bindings.node_t()
  defp normal_trie do
    Bindings.new()
    |> Bindings.bind(~k(RET), :tree_open_or_toggle, "Open file / toggle directory")
    |> Bindings.bind(~k(TAB), :tree_toggle_directory, "Toggle directory")
    |> Bindings.bind(~k(l), :tree_expand, "Expand directory")
    |> Bindings.bind(~k(h), :tree_collapse, "Collapse directory")
    |> Bindings.bind(~k(H), :tree_toggle_hidden, "Toggle hidden files")
    |> Bindings.bind(~k(r), :tree_refresh, "Refresh file tree")
    |> Bindings.bind(~k(-), :tree_root_parent, "Root tree at parent")
    |> Bindings.bind(~k(.), :tree_root_selected, "Root tree at selected directory")
    |> Bindings.bind(~k(~), :tree_root_original, "Root tree at project")
    |> Bindings.bind(~k(/), :tree_filter, "Filter file tree")
    |> Bindings.bind(~k(?), :tree_toggle_help, "Toggle help overlay")
    |> Bindings.bind(~k(q), :tree_close, "Close file tree")
    |> Bindings.bind(~k(ESC), :tree_close, "Close file tree")
    |> Bindings.bind(~k(a), :tree_new_file, "New file")
    |> Bindings.bind(~k(A), :tree_new_folder, "New folder")
    |> Bindings.bind(~k(R), :tree_rename, "Rename")
    |> Bindings.bind(~k(d), :tree_delete, "Delete")
    |> Bindings.bind(~k(y), :tree_copy_path, "Copy path")
    |> Bindings.bind(~k(c), :tree_mark_copy, "Mark for copy")
    |> Bindings.bind(~k(m), :tree_mark_move, "Mark for move")
    |> Bindings.bind(~k(p), :tree_paste, "Paste marked entry")
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
        |> Bindings.bind(~k(RET), :tree_open_or_toggle, "Open file / toggle directory")
        |> Bindings.bind(~k(ESC), :tree_close, "Close file tree")
        # Arrow left/right: collapse/expand (Finder-style)
        |> Bindings.bind([{57_351, 0}], :tree_expand, "Expand directory")
        |> Bindings.bind([{57_350, 0}], :tree_collapse, "Collapse directory")
        |> Bindings.bind([{0xF703, 0}], :tree_expand, "Expand directory")
        |> Bindings.bind([{0xF702, 0}], :tree_collapse, "Collapse directory")
      end
    )
  end
end
