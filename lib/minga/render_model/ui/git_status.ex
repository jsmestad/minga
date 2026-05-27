defmodule Minga.RenderModel.UI.GitStatus do
  @moduledoc false

  @type repo_state :: :normal | :not_a_repo | :loading

  @type toast_action :: :pull_and_retry | nil

  @type toast :: %{
          message: String.t(),
          level: :success | :error,
          action: toast_action()
        }

  @type file_entry :: %{
          path: String.t(),
          status: atom(),
          staged: boolean()
        }

  @type t :: %__MODULE__{
          repo_state: repo_state(),
          syncing: boolean(),
          branch: String.t(),
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          entries: [file_entry()],
          entry_base_path: String.t(),
          last_commit_message: String.t(),
          stash_count: non_neg_integer(),
          git_toast: toast() | nil
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
            git_toast: nil
end
