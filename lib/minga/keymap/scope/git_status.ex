defmodule Minga.Keymap.Scope.GitStatus do
  @moduledoc """
  Keymap scope for the git status panel (TUI).

  Provides navigation and git operation bindings: j/k to move between
  files, s/u/d to stage/unstage/discard, cc to start commit.
  Unmatched keys fall through to the global leader trie.

  The git status panel always operates in normal mode. Mode transitions
  to insert or visual are blocked.
  """

  @behaviour Minga.Keymap.Scope

  alias Minga.Keymap.Bindings

  @enter 13
  @escape 27
  @tab 9

  # ── Behaviour callbacks ────────────────────────────────────────────────

  @impl true
  @spec name() :: :git_status
  def name, do: :git_status

  @impl true
  @spec display_name() :: String.t()
  def display_name, do: "Git Status"

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(:normal, _context), do: normal_trie()
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
         {"J / K", "Jump to next / previous section"},
         {"gg / G", "Jump to top / bottom"},
         {"Tab", "Toggle section collapse"}
       ]},
      {"Actions",
       [
         {"s", "Stage file (or unstage if in Staged)"},
         {"u", "Unstage file"},
         {"d", "Discard changes (with confirmation)"},
         {"S", "Stage all"},
         {"U", "Unstage all"},
         {"o / Enter", "Open file in editor"},
         {"cc", "Start commit (enter message)"}
       ]},
      {"View",
       [
         {"q / Esc", "Close git status"}
       ]}
    ]
  end

  @impl true
  @spec on_enter(term()) :: term()
  def on_enter(state), do: state

  @impl true
  @spec on_exit(term()) :: term()
  def on_exit(state), do: state

  # ── Normal mode bindings ───────────────────────────────────────────────

  @spec normal_trie() :: Bindings.node_t()
  defp normal_trie do
    Bindings.new()
    # Navigation
    |> Bindings.bind([{?j, 0}], :git_status_next, "Next file")
    |> Bindings.bind([{?k, 0}], :git_status_prev, "Previous file")
    |> Bindings.bind([{?J, 0}], :git_status_next_section, "Next section")
    |> Bindings.bind([{?K, 0}], :git_status_prev_section, "Previous section")
    |> Bindings.bind([{@tab, 0}], :git_status_toggle_section, "Toggle section collapse")
    # Git operations
    |> Bindings.bind([{?s, 0}], :git_status_stage, "Stage file")
    |> Bindings.bind([{?u, 0}], :git_status_unstage, "Unstage file")
    |> Bindings.bind([{?d, 0}], :git_status_discard, "Discard changes")
    |> Bindings.bind([{?S, 0}], :git_status_stage_all, "Stage all")
    |> Bindings.bind([{?U, 0}], :git_status_unstage_all, "Unstage all")
    # Open/commit
    |> Bindings.bind([{?o, 0}], :git_status_open_file, "Open file")
    |> Bindings.bind([{@enter, 0}], :git_status_open_file, "Open file")
    |> Bindings.bind([{?c, 0}, {?c, 0}], :git_status_start_commit, "Start commit")
    # Close
    |> Bindings.bind([{?q, 0}], :git_status_close, "Close git status")
    |> Bindings.bind([{@escape, 0}], :git_status_close, "Close git status")
  end
end
