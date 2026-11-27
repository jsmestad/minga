defmodule Minga.Keymap.Scope.TaskReview do
  @moduledoc "Bindings for the focused task review buffer."

  use Minga.Keymap.Scope.Builder, name: :task_review, display_name: "Task Review"

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope

  import Minga.Keymap.Sigil

  @entries [
    {~k(y), :task_review_keep, "Keep change"},
    {~k(n), :task_review_reject, "Reject change"},
    {~k(=), :task_review_diff, "Toggle inline diff"},
    {~k(Y), :task_review_keep_all, "Keep all changes"},
    {~k(] h), :task_review_next, "Next change"},
    {~k([ h), :task_review_previous, "Previous change"},
    {~k(] q), :quickfix_next, "Next quickfix location"},
    {~k([ q), :quickfix_previous, "Previous quickfix location"},
    {~k(RET), :task_review_jump, "Go to change"},
    {~k(q), :task_review_close, "Close review"},
    {~k(ESC), :task_review_escape, "Dismiss review or preview"}
  ]

  @impl true
  @spec keymap(Scope.vim_state(), Scope.context()) :: Bindings.node_t()
  def keymap(mode, _context) when mode in [:normal, :cua] do
    Enum.reduce(@entries, Bindings.new(), fn {keys, command, description}, trie ->
      Bindings.bind(trie, keys, command, description)
    end)
  end

  def keymap(_mode, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec help_groups(atom()) :: [Scope.help_group()]
  def help_groups(_focus) do
    [
      {"Task Review",
       [
         {"y / n", "Keep or reject"},
         {"=", "Toggle inline diff"},
         {"Y", "Keep all changes"},
         {"]h / [h", "Move between changes"},
         {"↩", "Go to change"},
         {"q", "Close review"}
       ]}
    ]
  end
end
