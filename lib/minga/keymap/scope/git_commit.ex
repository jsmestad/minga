defmodule Minga.Keymap.Scope.GitCommit do
  @moduledoc """
  Keymap scope for the git commit message buffer (Magit-style).

  Provides C-c C-c to commit, C-c C-k to abort, and q (normal mode)
  as a convenience quit. In insert mode, unmatched keys pass through
  to the Mode FSM for normal text editing.
  """

  use Minga.Keymap.Scope.Builder,
    name: :git_commit,
    display_name: "Git Commit"

  alias Minga.Keymap.Bindings

  @escape 27
  @ctrl 0x02

  # ── Keymap ─────────────────────────────────────────────────────────────────

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(:normal, _context), do: normal_trie()
  def keymap(:insert, _context), do: insert_trie()
  def keymap(_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: shared_trie()

  @impl true
  @spec help_groups(atom()) :: [Minga.Keymap.Scope.help_group()]
  def help_groups(_focus) do
    [
      {"Commit",
       [
         {"C-c C-c", "Commit and close"},
         {"C-c C-k", "Abort and close"}
       ]},
      {"View",
       [
         {"q", "Abort (normal mode)"},
         {"Esc", "Return to normal mode (from insert)"}
       ]}
    ]
  end

  # ── Shared bindings (both normal and insert) ───────────────────────────

  @spec shared_trie() :: Bindings.node_t()
  defp shared_trie do
    Bindings.new()
    |> Bindings.bind([{?c, @ctrl}, {?c, @ctrl}], :git_commit_execute, "Commit and close")
    |> Bindings.bind([{?c, @ctrl}, {?k, @ctrl}], :git_commit_abort, "Abort and close")
  end

  # ── Normal mode bindings ───────────────────────────────────────────────

  @spec normal_trie() :: Bindings.node_t()
  defp normal_trie do
    Bindings.new()
    |> Bindings.bind([{?q, 0}], :git_commit_abort, "Abort commit")
  end

  # ── Insert mode bindings ───────────────────────────────────────────────

  @spec insert_trie() :: Bindings.node_t()
  defp insert_trie do
    Bindings.new()
    |> Bindings.bind([{@escape, 0}], :git_commit_to_normal, "Normal mode")
  end
end
