defmodule Minga.Keymap.Scope.Queue do
  @moduledoc "Bindings for the conversation's focused list of queued messages."

  use Minga.Keymap.Scope.Builder, name: :queue, display_name: "Queue"

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope

  import Minga.Keymap.Sigil

  @arrows_up [57_352, 0xF700]
  @arrows_down [57_353, 0xF701]

  @impl true
  @spec keymap(Scope.vim_state(), Scope.context()) :: Bindings.node_t()
  def keymap(mode, _context) when mode in [:normal, :cua] do
    Bindings.new()
    |> Bindings.bind(~k(j), :queue_next, "Next message")
    |> Bindings.bind(~k(k), :queue_previous, "Previous message")
    |> bind_arrows(@arrows_down, :queue_next, "Next message")
    |> bind_arrows(@arrows_up, :queue_previous, "Previous message")
    |> Bindings.bind(~k(d d), :queue_remove, "Remove message")
    |> Bindings.bind(~k(p), :queue_paste_after, "Put back after")
    |> Bindings.bind(~k(P), :queue_paste_before, "Put back before")
    |> Bindings.bind(~k(RET), :queue_edit, "Edit message")
    |> Bindings.bind(~k(q), :queue_close, "Close queue")
  end

  def keymap(_mode, _context), do: Bindings.new()

  @spec bind_arrows(Bindings.node_t(), [non_neg_integer()], atom(), String.t()) ::
          Bindings.node_t()
  defp bind_arrows(trie, arrows, command, description) do
    Enum.reduce(arrows, trie, &Bindings.bind(&2, [{&1, 0}], command, description))
  end

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec help_groups(atom()) :: [Scope.help_group()]
  def help_groups(_focus) do
    [
      {"Queue",
       [
         {"j / k", "Move"},
         {"dd", "Remove message"},
         {"p / P", "Put back after / before"},
         {"↩", "Edit message"},
         {"q", "Close queue"}
       ]}
    ]
  end
end
