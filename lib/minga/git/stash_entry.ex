defmodule Minga.Git.StashEntry do
  @moduledoc "Structured information about a git stash."

  @enforce_keys [:index, :ref, :message, :date]
  defstruct [:index, :ref, :message, :date]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          ref: String.t(),
          message: String.t(),
          date: String.t()
        }
end
