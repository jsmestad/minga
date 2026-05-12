defmodule Minga.Keymap.Scope.Dired do
  @moduledoc """
  Keymap scope for Oil.nvim-style directory buffers.

  Binds only navigation and toggle keys. All other keys fall through
  to the Mode FSM, making the buffer fully editable with standard vim
  motions, operators, and ex commands. Saving (`:w`) triggers the
  diff-and-apply workflow instead of writing to disk.
  """

  use Minga.Keymap.Scope.Builder,
    name: :dired,
    display_name: "Dired"

  alias Minga.Keymap.Bindings

  @enter 13
  @escape 27

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
         {"Enter", "Open file / enter directory"},
         {"-", "Go to parent directory"},
         {"j / k", "Move cursor down / up"},
         {"gg / G", "Jump to top / bottom"}
       ]},
      {"Display",
       [
         {"g.", "Toggle hidden files"},
         {"gs", "Cycle sort order (name → size → date → extension)"},
         {"gd", "Toggle detail columns"},
         {"gx", "Open with system application"},
         {"g (alone)", "Refresh listing"}
       ]},
      {"Editing",
       [
         {"i / A / o / O", "Enter insert mode (edit filenames)"},
         {"dd", "Delete line (deletes file on :w)"},
         {":s/old/new/", "Rename matching files on :w"},
         {":w", "Apply all changes (rename/delete/create)"}
       ]},
      {"View",
       [
         {"q / Esc", "Close directory buffer"}
       ]}
    ]
  end

  # ── Normal mode bindings ───────────────────────────────────────────────────

  @spec normal_trie() :: Bindings.node_t()
  defp normal_trie do
    Bindings.new()
    |> Bindings.bind([{@enter, 0}], :dired_open_entry, "Open file / enter directory")
    |> Bindings.bind([{?-, 0}], :dired_parent, "Parent directory")
    |> Bindings.bind([{?q, 0}], :dired_close, "Close directory buffer")
    |> Bindings.bind([{@escape, 0}], :dired_close, "Close directory buffer")
    |> Bindings.bind([{?g, 0}, {?., 0}], :dired_toggle_hidden, "Toggle hidden files")
    |> Bindings.bind([{?g, 0}, {?s, 0}], :dired_cycle_sort, "Cycle sort order")
    |> Bindings.bind([{?g, 0}, {?d, 0}], :dired_toggle_details, "Toggle detail columns")
    |> Bindings.bind([{?g, 0}, {?x, 0}], :dired_open_external, "Open with system application")
    |> Bindings.bind([{?g, 0}, {?r, 0}], :dired_refresh, "Refresh listing")
  end

  # ── CUA mode bindings ─────────────────────────────────────────────────────

  @spec cua_trie() :: Bindings.node_t()
  defp cua_trie do
    build_trie(
      groups: @cua_groups,
      then: fn trie ->
        trie
        |> Bindings.bind([{@enter, 0}], :dired_open_entry, "Open file / enter directory")
        |> Bindings.bind([{@escape, 0}], :dired_close, "Close directory buffer")
      end
    )
  end
end
