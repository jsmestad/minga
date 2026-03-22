defmodule Minga.Picker.GitBranchSource do
  @moduledoc """
  Picker source for switching, creating, and deleting git branches.

  Lists all local branches first, then remote branches below a separator.
  The current branch shows a checkmark annotation. Typing a name that
  doesn't match any branch shows a "Create branch" option.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Git
  alias Minga.Git.Repo, as: GitRepo
  alias Minga.Log
  alias Minga.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch Branch"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
    root = Minga.Project.resolve_root()

    case Git.root_for(root) do
      {:ok, git_root} -> build_candidates(git_root)
      :not_git -> []
    end
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:create, name}}, state) do
    case resolve_git_root() do
      nil ->
        %{state | status_msg: "Not in a git repository"}

      git_root ->
        case Git.branch_create(git_root, name) do
          :ok ->
            refresh_repo(git_root)
            %{state | status_msg: "Created and switched to #{name}"}

          {:error, reason} ->
            %{state | status_msg: "Failed: #{reason}"}
        end
    end
  end

  def on_select(%Item{id: {:branch, name}}, state) do
    case resolve_git_root() do
      nil ->
        %{state | status_msg: "Not in a git repository"}

      git_root ->
        case Git.branch_switch(git_root, name) do
          :ok ->
            refresh_repo(git_root)
            %{state | status_msg: "Switched to #{name}"}

          {:error, reason} ->
            %{state | status_msg: "Failed: #{reason}"}
        end
    end
  end

  def on_select(_, state), do: state

  @impl true
  def on_cancel(state), do: state

  # ── Private ────────────────────────────────────────────────────────────

  @spec build_candidates(String.t()) :: [Item.t()]
  defp build_candidates(git_root) do
    case Git.branch_list(git_root) do
      {:ok, branches} ->
        {local, remote} = Enum.split_with(branches, fn b -> not b.remote end)

        local_items = Enum.map(local, &format_branch/1)
        remote_items = Enum.map(remote, &format_branch/1)

        local_items ++ remote_items

      {:error, reason} ->
        Log.warning(:editor, "[branch_picker] branch_list failed: #{reason}")
        []
    end
  end

  @spec format_branch(Git.BranchInfo.t()) :: Item.t()
  defp format_branch(branch) do
    annotation =
      cond do
        branch.current -> "✓"
        branch.remote -> "remote"
        true -> nil
      end

    %Item{
      id: {:branch, branch.name},
      label: branch.name,
      description: branch_description(branch),
      annotation: annotation
    }
  end

  @spec branch_description(Git.BranchInfo.t()) :: String.t()
  defp branch_description(branch) do
    parts = []
    parts = if branch.upstream, do: ["→ #{branch.upstream}" | parts], else: parts

    parts =
      if branch.ahead && branch.ahead > 0,
        do: ["↑#{branch.ahead}" | parts],
        else: parts

    parts =
      if branch.behind && branch.behind > 0,
        do: ["↓#{branch.behind}" | parts],
        else: parts

    Enum.reverse(parts) |> Enum.join(" ")
  end

  @spec resolve_git_root() :: String.t() | nil
  defp resolve_git_root do
    root = Minga.Project.resolve_root()

    case Git.root_for(root) do
      {:ok, git_root} -> git_root
      :not_git -> nil
    end
  end

  @spec refresh_repo(String.t()) :: :ok
  defp refresh_repo(git_root) do
    case GitRepo.lookup(git_root) do
      nil -> :ok
      pid -> GitRepo.refresh(pid)
    end
  end
end
