defmodule MingaEditor.GitStatus.CleanTree do
  @moduledoc """
  What git status says when there is nothing to commit, and the next steps it offers, in the panel's own keys: push when commits wait to go up, pull when commits wait to come down, and fetch to check.

  A clean tree is a finished, good state, so it carries the Done glyph and no warning colour (`design/boards/Batch4_git_ext_queue_empty.dc.html`). The builder draws it and the panel's keys run the preselected step, so both read the same steps.
  """

  alias Minga.RenderModel.UI.EmptyList
  alias MingaEditor.RenderModel.UI.EmptyStateBuilder

  @done_glyph "●"

  @typedoc "What the clean tree knows: its branch and how far it is from its upstream."
  @type facts :: %{branch: String.t() | nil, ahead: non_neg_integer(), behind: non_neg_integer()}

  @doc "The empty-state anatomy for a clean tree, with `selected` preselected."
  @spec empty_list(facts(), non_neg_integer()) :: EmptyList.t()
  def empty_list(%{branch: branch} = facts, cursor) do
    EmptyStateBuilder.empty_list(title(branch), why(facts), steps(facts),
      glyph: @done_glyph,
      selected: selected_index(facts, cursor)
    )
  end

  @doc "The commands of a clean tree's next steps, in order."
  @spec commands(facts()) :: [atom()]
  def commands(facts), do: Enum.map(steps(facts), fn {command, _label, _key} -> command end)

  @doc """
  The step the panel's cursor selects: the cursor's own step, or the first step when the cursor is past the last one, as when the tree has just become clean with the cursor on a file row, or a push has just removed the Push step.

  The builder highlights this step and ↩ runs it, so both read this one rule.
  """
  @spec selected_index(facts(), non_neg_integer()) :: non_neg_integer()
  def selected_index(facts, cursor) when is_integer(cursor) and cursor >= 0 do
    if cursor < length(steps(facts)), do: cursor, else: 0
  end

  @doc "The command of the step the cursor selects."
  @spec command_at(facts(), non_neg_integer()) :: atom()
  def command_at(facts, cursor), do: Enum.at(commands(facts), selected_index(facts, cursor))

  @spec steps(facts()) :: [EmptyStateBuilder.step()]
  defp steps(%{ahead: ahead, behind: behind}) do
    push = if ahead > 0, do: [{:git_status_push, "Push to remote", "P"}], else: []
    pull = [{:git_status_pull, "Pull from remote", "l"}]
    fetch = [{:git_status_fetch, "Fetch from remote", "f"}]
    if behind > 0, do: pull ++ push ++ fetch, else: push ++ pull ++ fetch
  end

  @spec title(String.t() | nil) :: String.t()
  defp title(branch) when branch in [nil, ""], do: "Nothing to commit."
  defp title(branch), do: "Nothing to commit on #{branch}."

  @spec why(facts()) :: String.t()
  defp why(%{ahead: 0, behind: 0}), do: "Up to date with its upstream."
  defp why(%{ahead: ahead, behind: 0}), do: "#{commits(ahead)} to push."
  defp why(%{ahead: 0, behind: behind}), do: "#{commits(behind)} to pull."

  defp why(%{ahead: ahead, behind: behind}),
    do: "#{commits(ahead)} to push, #{commits(behind)} to pull."

  @spec commits(pos_integer()) :: String.t()
  defp commits(1), do: "1 commit"
  defp commits(n), do: "#{n} commits"
end
