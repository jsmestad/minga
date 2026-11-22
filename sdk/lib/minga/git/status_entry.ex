defmodule Minga.Git.StatusEntry do
  @moduledoc "Status of one path. Staged and unstaged changes to the same path may be separate entries."
  @enforce_keys [:path, :status, :staged]
  defstruct [:path, :status, :staged]

  @type t :: %__MODULE__{
          path: String.t(),
          status:
            :added
            | :modified
            | :deleted
            | :renamed
            | :copied
            | :untracked
            | :conflict
            | :unknown,
          staged: boolean()
        }
end
