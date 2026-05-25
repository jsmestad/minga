defmodule MingaGitPorcelain do
  @moduledoc """
  Bundled Git porcelain UI extension for Minga.

  Core Git backend primitives stay in `Minga.Git`. This extension owns the user-facing porcelain: commands, keybindings, Git status input scope, picker sources, prompts, and commit-message generation UI.
  """

  use Minga.Extension

  command :git_status_toggle, "Git status", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_status_toggle}
  command :git_changed_files, "Changed files", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_changed_files}
  command :git_log, "Git log", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_log}
  command :git_log_file, "Git log for current file", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_log_file}
  command :git_branch_picker, "Switch branch", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_branch_picker}
  command :git_stash_save, "Stash changes", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_stash_save}
  command :git_stash_pop, "Pop stash", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_stash_pop}
  command :git_stash_list, "List stashes", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_stash_list}
  command :git_stash_drop, "Drop stash", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_stash_drop}
  command :git_push, "Push", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_push}
  command :git_pull, "Pull", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_pull}
  command :git_fetch, "Fetch", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_fetch}
  command :git_pull_and_retry, "Pull and retry push", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_pull_and_retry}
  command :git_diff_file, "View diff", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_diff_file}
  command :git_diff_toggle_layout, "Toggle side-by-side diff", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_diff_toggle_layout}
  command :next_git_hunk, "Next git hunk", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :next_git_hunk}
  command :prev_git_hunk, "Previous git hunk", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :prev_git_hunk}
  command :next_merge_conflict, "Next merge conflict", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :next_merge_conflict}
  command :prev_merge_conflict, "Previous merge conflict", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :prev_merge_conflict}
  command :git_accept_current_conflict, "Accept current conflict side", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_accept_current_conflict}
  command :git_accept_incoming_conflict, "Accept incoming conflict side", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_accept_incoming_conflict}
  command :git_accept_both_conflict, "Accept both conflict sides", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_accept_both_conflict}
  command :git_stage_hunk, "Stage hunk", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_stage_hunk}
  command :git_stage_file, "Stage current file", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_stage_file}
  command :git_unstage_file, "Unstage current file", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_unstage_file}
  command :git_revert_hunk, "Revert hunk", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_revert_hunk}
  command :git_preview_hunk, "Preview hunk", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_preview_hunk}
  command :git_blame_line, "Blame line", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_blame_line}
  command :git_commit_open, "Open commit panel", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_commit_open}
  command :git_amend_open, "Open amend panel", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_amend_open}
  command :git_diff_toggle_staged, "Toggle diff staged/unstaged", requires_buffer: true, execute: {MingaGitPorcelain.Commands, :git_diff_toggle_staged}
  command :git_generate_commit_message, "Generate AI commit message", requires_buffer: false, execute: {MingaGitPorcelain.Commands, :git_generate_commit_message}

  keybind :normal, "SPC g g", :git_status_toggle, "Git status"
  keybind :normal, "SPC g f", :git_changed_files, "Changed files"
  keybind :normal, "SPC g l", :git_log, "Git log"
  keybind :normal, "SPC g B", :git_branch_picker, "Switch branch"
  keybind :normal, "SPC g P", :git_push, "Push"
  keybind :normal, "SPC g p", :git_pull, "Pull"
  keybind :normal, "SPC g F", :git_fetch, "Fetch"
  keybind :normal, "SPC g d", :git_diff_file, "View diff"
  keybind :normal, "SPC g s", :git_stage_file, "Stage file"
  keybind :normal, "SPC g u", :git_unstage_file, "Unstage file"
  keybind :normal, "SPC g r", :git_revert_hunk, "Revert hunk"
  keybind :normal, "SPC g v", :git_preview_hunk, "Preview hunk"
  keybind :normal, "SPC g b", :git_blame_line, "Blame line"
  keybind :normal, "SPC g c c", :git_commit_open, "Commit"
  keybind :normal, "SPC g c a", :git_amend_open, "Amend commit"
  keybind :normal, "SPC g D", :git_diff_toggle_staged, "Toggle staged/unstaged diff"
  keybind :normal, "SPC g x c", :git_accept_current_conflict, "Accept current conflict"
  keybind :normal, "SPC g x i", :git_accept_incoming_conflict, "Accept incoming conflict"
  keybind :normal, "SPC g x b", :git_accept_both_conflict, "Accept both conflict sides"
  keybind :normal, "SPC g z z", :git_stash_save, "Stash changes"
  keybind :normal, "SPC g z p", :git_stash_pop, "Pop stash"
  keybind :normal, "SPC g z l", :git_stash_list, "List stashes"
  keybind :normal, "SPC g z d", :git_stash_drop, "Drop stash"
  keybind :normal, "SPC g c g", :git_generate_commit_message, "Generate AI commit message"

  @impl true
  def name, do: :minga_git_porcelain

  @impl true
  def description, do: "Git porcelain UI"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config) do
    MingaGitPorcelain.Feature.register_contributions()
    {:ok, %{}}
  end
end
