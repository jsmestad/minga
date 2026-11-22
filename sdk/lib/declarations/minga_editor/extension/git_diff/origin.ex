defmodule MingaEditor.Extension.GitDiff.Origin do
  @moduledoc """
  The explicit repository, repository-relative path, and section of a diff view.

  A view opened from a working buffer can retain its exact `source_buffer`.
  Leave it unset for a snapshot opened from a repository listing.

  `:unstaged` compares the index to working text. `:staged` compares HEAD to the index.
  A `:conflict` preview compares HEAD to the conflicted worktree and does not offer hunk mutations.
  """

  @enforce_keys [:git_root, :rel_path, :section]
  defstruct [:git_root, :rel_path, :section, :source_buffer]

  @type section :: :unstaged | :staged | :conflict

  @type t :: %__MODULE__{
          git_root: String.t(),
          rel_path: String.t(),
          section: section(),
          source_buffer: pid() | nil
        }
end
