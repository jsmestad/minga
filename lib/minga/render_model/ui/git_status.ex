defmodule Minga.RenderModel.UI.GitStatus do
  @moduledoc false

  @type repo_state :: :normal | :not_a_repo | :loading

  @type toast_action :: :none | :pull_and_retry

  @typedoc """
  A wire-shaped git status entry. The Layer 2 builder derives `path_hash` and
  the `section` byte (ruling 4) so the adapter passes each entry straight to the
  generated `encode_git_status_entry/1`.
  """
  @type wire_entry :: %{
          path_hash: non_neg_integer(),
          section: non_neg_integer(),
          status: atom(),
          path: String.t()
        }

  @typedoc """
  A wire-shaped git toast. The builder normalizes a missing toast to
  `%{present: 0}` and a present toast to the full presence-byte map, keeping the
  wire non-nullable.
  """
  @type wire_toast ::
          %{present: 0}
          | %{
              present: 1,
              level: :success | :error,
              action: toast_action(),
              message: String.t()
            }

  @type t :: %__MODULE__{
          repo_state: repo_state(),
          syncing: boolean(),
          branch: String.t(),
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          entries: [wire_entry()],
          entry_base_path: String.t(),
          last_commit_message: String.t(),
          stash_count: non_neg_integer(),
          git_toast: wire_toast()
        }

  @enforce_keys [:repo_state, :syncing]
  defstruct repo_state: :not_a_repo,
            syncing: false,
            branch: "",
            ahead: 0,
            behind: 0,
            entries: [],
            entry_base_path: "",
            last_commit_message: "",
            stash_count: 0,
            git_toast: %{present: 0}
end
