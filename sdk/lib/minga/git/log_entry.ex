defmodule Minga.Git.LogEntry do
  @moduledoc "Structured information about a Git commit."
  @enforce_keys [:hash, :short_hash, :author, :date, :message]
  defstruct [:hash, :short_hash, :author, :date, :message]

  @type t :: %__MODULE__{
          hash: String.t(),
          short_hash: String.t(),
          author: String.t(),
          date: String.t(),
          message: String.t()
        }
end
