defmodule MingaDired.Entry do
  @moduledoc """
  A single directory entry with filesystem metadata.

  Used by `MingaDired.Core` to represent files, directories, and symlinks.
  """

  @enforce_keys [:path, :name]
  defstruct [
    :path,
    :name,
    dir?: false,
    symlink?: false,
    target: nil,
    executable?: false,
    size: 0,
    mtime: nil,
    mode: 0
  ]

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          dir?: boolean(),
          symlink?: boolean(),
          target: String.t() | nil,
          executable?: boolean(),
          size: non_neg_integer(),
          mtime: NaiveDateTime.t() | nil,
          mode: non_neg_integer()
        }
end
