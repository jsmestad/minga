defmodule Minga.Keymap.Scope.Editor do
  @moduledoc """
  Keymap scope for normal text editing.

  This is the default scope. It provides no scope-specific bindings because
  the existing `Mode` system (normal, insert, visual, etc.) handles all
  editor keybindings. The scope exists so the resolution system has a
  uniform interface for all contexts.

  The input router falls through to `Mode.process/3` when the editor scope
  returns `:not_found` for a key.
  """

  @behaviour Minga.Keymap.Scope

  alias Minga.Keymap.Bindings

  @impl true
  @spec name() :: :editor
  def name, do: :editor

  @impl true
  @spec display_name() :: String.t()
  def display_name, do: "Editor"

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(_vim_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec on_enter(term()) :: term()
  def on_enter(state), do: state

  @impl true
  @spec on_exit(term()) :: term()
  def on_exit(state), do: state
end
