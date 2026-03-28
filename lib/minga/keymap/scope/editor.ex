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

  @behaviour Minga.Keymap.Scope

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.CUADefaults

  @impl true
  @spec name() :: :editor
  def name, do: :editor

  @impl true
  @spec display_name() :: String.t()
  def display_name, do: "Editor"

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

  @impl true
  @spec included_groups() :: [atom() | {atom(), keyword()}]
  def included_groups, do: [:cua_cmd_chords]

  @impl true
  @spec on_enter(term()) :: term()
  def on_enter(state), do: state

  @impl true
  @spec on_exit(term()) :: term()
  def on_exit(state), do: state

  # ── CUA bindings ───────────────────────────────────────────────────────

  @ctrl 0x02

  @spec cua_trie() :: Bindings.node_t()
  defp cua_trie do
    CUADefaults.cmd_chords_trie()
    |> Bindings.bind([{?p, @ctrl}], :command_palette, "Command palette")
  end
end
