defmodule Minga.Keymap.Scope.SubagentPeek do
  @moduledoc "Bindings for inspecting a subagent, separate from its composer."

  use Minga.Keymap.Scope.Builder, name: :subagent_peek, display_name: "Subagent Peek"

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope

  import Minga.Keymap.Sigil

  @impl true
  @spec keymap(Scope.vim_state(), Scope.context()) :: Bindings.node_t()
  def keymap(mode, _context) when mode in [:normal, :cua] do
    Bindings.new()
    |> Bindings.bind(~k(] ]), :subagent_peek_next, "Next sibling")
    |> Bindings.bind(~k([ [), :subagent_peek_previous, "Previous sibling")
    |> Bindings.bind(~k(z a), :subagent_peek_brief, "Toggle brief")
    |> Bindings.bind(~k(q), :subagent_peek_close, "Close peek")
    |> Bindings.bind(~k(i), :subagent_peek_compose, "Message this subagent")
  end

  def keymap(_mode, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec help_groups(atom()) :: [Scope.help_group()]
  def help_groups(_focus) do
    [
      {"Subagent Peek",
       [
         {"]] / [[", "Step between siblings"},
         {"za", "Toggle brief"},
         {"i", "Message this subagent"},
         {"q", "Close peek"}
       ]}
    ]
  end
end
