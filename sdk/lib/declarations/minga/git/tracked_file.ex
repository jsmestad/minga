defmodule Minga.Git.TrackedFile do
  @moduledoc """
  A Git-tracked buffer observation and its changes against cached HEAD.

  `path` is relative to `root`. `base` is `nil` when the file is absent
  from HEAD. `content`, `cursor`, and `version` describe one buffer state.
  """

  @enforce_keys [:root, :path, :base, :content, :version, :cursor, :hunks]
  defstruct [:root, :path, :base, :content, :version, :cursor, :hunks]

  @type t :: %__MODULE__{
          root: binary(),
          path: binary(),
          base: binary() | nil,
          content: binary(),
          version: non_neg_integer(),
          cursor: {line :: non_neg_integer(), col :: non_neg_integer()},
          hunks: [Minga.Git.change()]
        }
end
