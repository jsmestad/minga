defmodule Minga.Keymap.Scope.GitStatus do
  @moduledoc """
  Keymap scope for the git status panel (TUI).

  Provides navigation and git operation bindings: j/k to move between
  files, s/u/d to stage/unstage/discard, cc to start commit.
  Unmatched keys fall through to the global leader trie.

  The git status panel always operates in normal mode. Mode transitions
  to insert or visual are blocked.
  """

  use Minga.Keymap.Scope.Builder,
    name: :git_status,
    display_name: "Git Status"

  alias Minga.Keymap.Bindings

  import Minga.Keymap.Sigil

  @cmd 0x08

  # Groups included by this scope.
  @cua_groups [:cua_navigation, {:cua_cmd_chords, exclude: [:save]}]

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
         {"p", "Preview diff"},
         {"P", "Push to remote"},
         {"l", "Pull from remote"},
         {"f", "Fetch from remote"},
         {"cc", "Start commit (enter message)"},
         {"ca", "Amend last commit"},
         {"cg", "Generate AI commit message"}
       ]},
      {"Discard Confirmation",
       [
         {"y", "Confirm discard"},
         {"n / Esc", "Cancel discard"}
       ]},
      {"View",
       [
         {"q / Esc", "Close git status"}
       ]}
    ]
  end

  # ── Normal mode bindings ───────────────────────────────────────────────

  @spec normal_trie() :: Bindings.node_t()
  defp normal_trie do
    Bindings.new()
    # Navigation
    |> Bindings.bind(~k(j), :git_status_next, "Next file")
    |> Bindings.bind(~k(k), :git_status_prev, "Previous file")
    |> Bindings.bind(~k(J), :git_status_next_section, "Next section")
    |> Bindings.bind(~k(K), :git_status_prev_section, "Previous section")
    |> Bindings.bind(~k(TAB), :git_status_toggle_section, "Toggle section collapse")
    # Git operations
    |> Bindings.bind(~k(s), :git_status_stage, "Stage file")
    |> Bindings.bind(~k(u), :git_status_unstage, "Unstage file")
    |> Bindings.bind(~k(d), :git_status_discard, "Discard changes")
    |> Bindings.bind(~k(S), :git_status_stage_all, "Stage all")
    |> Bindings.bind(~k(U), :git_status_unstage_all, "Unstage all")
    # Diff and remote operations
    |> Bindings.bind(~k(p), :git_status_open_diff, "Preview diff")
    |> Bindings.bind(~k(P), :git_status_push, "Push to remote")
    |> Bindings.bind(~k(l), :git_status_pull, "Pull from remote")
    |> Bindings.bind(~k(f), :git_status_fetch, "Fetch from remote")
    # Open/commit
    |> Bindings.bind(~k(o), :git_status_open_file, "Open file")
    |> Bindings.bind(~k(RET), :git_status_open_file, "Open file")
    |> Bindings.bind(~k(c c), :git_status_start_commit, "Start commit")
    |> Bindings.bind(~k(c a), :git_status_amend, "Amend last commit")
    |> Bindings.bind(~k(c g), :git_generate_commit_message, "Generate AI commit message")
    # Discard confirmation
    |> Bindings.bind(~k(y), :git_status_confirm_discard, "Confirm discard")
    |> Bindings.bind(~k(n), :git_status_cancel_discard, "Cancel discard")
    # Close
    |> Bindings.bind(~k(q), :git_status_close, "Close git status")
    |> Bindings.bind(~k(ESC), :git_status_close, "Close git status")
  end

  # ── CUA mode bindings ─────────────────────────────────────────────────

  @spec cua_trie() :: Bindings.node_t()
  defp cua_trie do
    build_trie(
      groups: @cua_groups,
      then: fn trie ->
        trie
        # Git operations (same keys as normal, domain-specific not vim-specific)
        |> Bindings.bind(~k(s), :git_status_stage, "Stage file")
        |> Bindings.bind(~k(u), :git_status_unstage, "Unstage file")
        |> Bindings.bind(~k(d), :git_status_discard, "Discard changes")
        |> Bindings.bind(~k(TAB), :git_status_toggle_section, "Toggle section collapse")
        # Open/commit
        |> Bindings.bind(~k(RET), :git_status_open_file, "Open file")
        |> Bindings.bind([{?c, @cmd}], :git_status_start_commit, "Start commit")
        |> Bindings.bind(~k(C-c), :git_status_start_commit, "Start commit")
        # Close
        |> Bindings.bind(~k(ESC), :git_status_close, "Close git status")
      end
    )
  end
end
