defmodule Minga.Git.BranchInfo do
  @moduledoc "Structured information about a Git branch."
  @enforce_keys [:name, :current]
  defstruct [:name, :current, upstream: nil, remote: false, ahead: nil, behind: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          current: boolean(),
          upstream: String.t() | nil,
          remote: boolean(),
          ahead: non_neg_integer() | nil,
          behind: non_neg_integer() | nil
        }
end
