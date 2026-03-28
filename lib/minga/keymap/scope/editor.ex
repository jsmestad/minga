defmodule Minga.Keymap.Scope.Editor do
  @moduledoc """
  Keymap scope for normal text editing.

  For vim modes (:normal, :insert, etc.), this scope provides no
  bindings because the Mode FSM handles all editor keybindings.

  For CUA mode, this scope provides Ctrl fallback bindings (undo,
  redo, paste, select-all, command palette) that terminals need
  because Cmd+key is intercepted by the terminal emulator. These
  bindings are resolved before `CUA.Dispatch` in the handler stack,
  which would otherwise silently eat Ctrl keys.

  The input router falls through to `Mode.process/3` (vim) or
  `CUA.Dispatch` (CUA) when this scope returns `:not_found`.
  """

  use Minga.Keymap.Scope.Builder,
    name: :editor,
    display_name: "Editor"

  alias Minga.Keymap.Bindings

  @ctrl 0x02

  # Groups included by this scope.
  @cua_groups [:cua_cmd_chords]

  @impl true
  @spec included_groups() :: [atom() | {atom(), keyword()}]
  def included_groups, do: @cua_groups

  # ── Keymap ─────────────────────────────────────────────────────────────────

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(:cua, _context), do: cua_trie()
  def keymap(_vim_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec help_groups(atom()) :: [Minga.Keymap.Scope.help_group()]
  def help_groups(_focus), do: []

  # ── CUA bindings ───────────────────────────────────────────────────────

  @spec cua_trie() :: Bindings.node_t()
  defp cua_trie do
    build_trie(
      groups: @cua_groups,
      then: fn trie ->
        trie
        |> Bindings.bind([{?p, @ctrl}], :command_palette, "Command palette")
      end
    )
  end
end
