defmodule MingaEditor.GitStatus.Panel do
  @moduledoc """
  Editor-owned shell state for the Git status panel.

  The Git porcelain extension owns the commands and rendering, but core shell state still needs a stable shape for GUI emission, dirty tracking, and disabled-extension fallbacks.
  """

  alias Minga.Git.StatusEntry

  @enforce_keys [:repo_state, :branch, :ahead, :behind, :entries]
  defstruct [
    :repo_state,
    :branch,
    :ahead,
    :behind,
    :entries,
    entry_base_path: nil,
    last_commit_message: nil,
    stash_count: nil
  ]

  @type repo_state :: :normal | :not_a_repo | :loading
  @type t :: %__MODULE__{
          repo_state: repo_state(),
          branch: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          entries: [StatusEntry.t()],
          entry_base_path: String.t() | nil,
          last_commit_message: String.t() | nil,
          stash_count: non_neg_integer() | nil
        }

  @doc "Builds a panel from extension or core panel data."
  @spec new(t() | map()) :: t()
  def new(%__MODULE__{} = panel), do: panel

  def new(%{} = attrs) do
    struct!(__MODULE__, %{
      repo_state: normalize_repo_state(Map.get(attrs, :repo_state, :normal)),
      branch: Map.get(attrs, :branch),
      ahead: Map.get(attrs, :ahead, 0),
      behind: Map.get(attrs, :behind, 0),
      entries: Map.get(attrs, :entries, []),
      entry_base_path: Map.get(attrs, :entry_base_path),
      last_commit_message: Map.get(attrs, :last_commit_message),
      stash_count: Map.get(attrs, :stash_count)
    })
  end

  @spec normalize_repo_state(term()) :: repo_state()
  defp normalize_repo_state(:not_git), do: :not_a_repo
  defp normalize_repo_state(:not_a_repo), do: :not_a_repo
  defp normalize_repo_state(:loading), do: :loading
  defp normalize_repo_state(_state), do: :normal

  @doc "Converts the stored panel to a plain map for wire encoders."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = panel), do: Map.from_struct(panel)
end
