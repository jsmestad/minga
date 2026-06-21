defmodule Minga.Git.Repo.StatusSnapshot do
  @moduledoc """
  Cached git status entries for a tracked repository.

  `entry_base_path` tells consumers which filesystem path the entry paths are relative to. This lets cache-only UI consumers render badges without shelling out to git.

  `degraded?`/`degraded_reason` flag when the cached entries are incomplete (e.g. `git status` timed out on a full checkout), so consumers can show a visible "degraded" indicator instead of silently trusting a trimmed list.
  """

  alias Minga.Git.StatusEntry

  @type degraded_reason :: Minga.Git.Repo.degraded_reason()

  @enforce_keys [:git_root, :entry_base_path, :entries]
  defstruct [:git_root, :entry_base_path, :entries, degraded?: false, degraded_reason: nil]

  @type t :: %__MODULE__{
          git_root: String.t(),
          entry_base_path: String.t(),
          entries: [StatusEntry.t()],
          degraded?: boolean(),
          degraded_reason: degraded_reason() | nil
        }

  @doc "Builds a cached status snapshot."
  @spec new(String.t(), String.t(), [StatusEntry.t()]) :: t()
  @spec new(String.t(), String.t(), [StatusEntry.t()], boolean(), degraded_reason() | nil) :: t()
  def new(git_root, entry_base_path, entries, degraded? \\ false, degraded_reason \\ nil)
      when is_binary(git_root) and is_binary(entry_base_path) and is_list(entries) and
             is_boolean(degraded?) do
    %__MODULE__{
      git_root: git_root,
      entry_base_path: entry_base_path,
      entries: entries,
      degraded?: degraded?,
      degraded_reason: degraded_reason
    }
  end
end
