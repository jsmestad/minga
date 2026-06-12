defmodule Minga.Git.Repo.StatusSnapshot do
  @moduledoc """
  Cached git status entries for a tracked repository.

  `entry_base_path` tells consumers which filesystem path the entry paths are relative to. This lets cache-only UI consumers render badges without shelling out to git.
  """

  alias Minga.Git.StatusEntry

  @enforce_keys [:git_root, :entry_base_path, :entries]
  defstruct [:git_root, :entry_base_path, :entries]

  @type t :: %__MODULE__{
          git_root: String.t(),
          entry_base_path: String.t(),
          entries: [StatusEntry.t()]
        }

  @doc "Builds a cached status snapshot."
  @spec new(String.t(), String.t(), [StatusEntry.t()]) :: t()
  def new(git_root, entry_base_path, entries)
      when is_binary(git_root) and is_binary(entry_base_path) and is_list(entries) do
    %__MODULE__{git_root: git_root, entry_base_path: entry_base_path, entries: entries}
  end
end
