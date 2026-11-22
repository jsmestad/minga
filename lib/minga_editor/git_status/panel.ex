defmodule MingaEditor.GitStatus.Panel do
  @moduledoc """
  Editor-owned shell state for the Git status panel.

  The host keeps the displayed repository and its cached snapshot together for rendering and actions.
  """

  alias Minga.Events.GitStatusEvent
  alias Minga.Git.Repo.StatusSnapshot
  alias Minga.Git.StatusEntry

  @enforce_keys [:id, :commit_target_id, :repo_state, :branch, :ahead, :behind, :entries]
  defstruct [
    :id,
    :commit_target_id,
    :repo_state,
    :branch,
    :ahead,
    :behind,
    :entries,
    git_root: nil,
    entry_base_path: nil,
    last_commit_message: nil,
    stash_count: nil
  ]

  @type id :: 1..0xFFFFFFFFFFFFFFFF
  @type repo_state :: :normal | :not_a_repo | :loading
  @type t :: %__MODULE__{
          id: id(),
          commit_target_id: id(),
          repo_state: repo_state(),
          branch: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          entries: [StatusEntry.t()],
          git_root: String.t() | nil,
          entry_base_path: String.t() | nil,
          last_commit_message: String.t() | nil,
          stash_count: non_neg_integer() | nil
        }

  @doc "Builds a panel from extension or core panel data."
  @spec new(t() | map()) :: t()
  def new(%__MODULE__{} = panel), do: panel

  def new(%{} = attrs) do
    id = new_id()

    struct!(__MODULE__, %{
      id: id,
      commit_target_id: id,
      repo_state: normalize_repo_state(Map.get(attrs, :repo_state, :normal)),
      branch: Map.get(attrs, :branch),
      ahead: Map.get(attrs, :ahead, 0),
      behind: Map.get(attrs, :behind, 0),
      entries: Map.get(attrs, :entries, []),
      git_root: Map.get(attrs, :git_root),
      entry_base_path: Map.get(attrs, :entry_base_path),
      last_commit_message: Map.get(attrs, :last_commit_message),
      stash_count: Map.get(attrs, :stash_count)
    })
  end

  @doc "Opens a panel from a cached repository snapshot."
  @spec from_repo_status(StatusSnapshot.t()) :: t()
  def from_repo_status(%StatusSnapshot{} = status) do
    id = new_id()
    from_repo_status(status, id, id)
  end

  @doc "Retires previous actions and keeps the commit target when the branch is unchanged."
  @spec refresh(t(), GitStatusEvent.t()) :: t()
  def refresh(%__MODULE__{git_root: root} = panel, %GitStatusEvent{git_root: root} = status) do
    id = new_id()

    commit_target_id =
      if (panel.branch || "") == (status.branch || ""), do: panel.commit_target_id, else: id

    from_repo_status(status, id, commit_target_id)
  end

  @doc "Assigns new snapshot and commit target identities when installing a replacement panel."
  @spec reinstall(t()) :: t()
  def reinstall(%__MODULE__{} = panel) do
    id = new_id()
    %{panel | id: id, commit_target_id: id}
  end

  @spec new_id() :: id()
  defp new_id, do: System.unique_integer([:positive, :monotonic])

  @spec from_repo_status(StatusSnapshot.t() | GitStatusEvent.t(), id(), id()) :: t()
  defp from_repo_status(status, id, commit_target_id) do
    %__MODULE__{
      id: id,
      commit_target_id: commit_target_id,
      repo_state: :normal,
      branch: status.branch || "",
      ahead: status.ahead,
      behind: status.behind,
      entries: status.entries,
      git_root: status.git_root,
      entry_base_path: status.entry_base_path || status.git_root,
      last_commit_message: status.last_commit_message,
      stash_count: status.stash_count
    }
  end

  @doc "Matches the offered row against the current panel instance and section."
  @spec entry(t() | nil, id(), String.t(), 0..3) :: StatusEntry.t() | nil
  def entry(%__MODULE__{id: id, entries: entries}, id, path, section) do
    Enum.reduce_while(entries, nil, fn
      %StatusEntry{path: ^path} = entry, found ->
        cond do
          section(entry) != section -> {:cont, found}
          is_nil(found) -> {:cont, entry}
          true -> {:halt, nil}
        end

      _entry, found ->
        {:cont, found}
    end)
  end

  def entry(_panel, _id, _path, _section), do: nil

  @doc "Resolves a displayed path against the base recorded in the panel snapshot."
  @spec absolute_path(t(), String.t()) :: {:ok, String.t()} | :error
  def absolute_path(%__MODULE__{git_root: root, entry_base_path: base}, path)
      when is_binary(root) and is_binary(path) do
    absolute = Path.expand(path, base || root)
    relative = Path.relative_to(absolute, root)

    if Path.type(relative) == :relative, do: {:ok, absolute}, else: :error
  end

  def absolute_path(%__MODULE__{}, _path), do: :error

  @doc "Returns the semantic section of a displayed entry."
  @spec section(%{
          required(:status) => atom(),
          required(:staged) => boolean(),
          optional(atom()) => term()
        }) ::
          0..3
  def section(%{status: :untracked}), do: 2
  def section(%{status: :conflict}), do: 3
  def section(%{staged: true}), do: 0
  def section(%{status: _, staged: false}), do: 1

  @spec normalize_repo_state(term()) :: repo_state()
  defp normalize_repo_state(:not_git), do: :not_a_repo
  defp normalize_repo_state(:not_a_repo), do: :not_a_repo
  defp normalize_repo_state(:loading), do: :loading
  defp normalize_repo_state(_state), do: :normal

  @doc "Converts the stored panel to a plain map for wire encoders."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = panel), do: Map.from_struct(panel)
end
