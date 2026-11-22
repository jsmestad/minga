defmodule MingaEditor.Extension.GitDiff.Target do
  @moduledoc """
  The exact snapshots shown in a semantic diff, with its origin and optional
  hunk at the rendered cursor. Context and folded rows have no hunk.

  `source_version` is present for a working diff attached to a source buffer.
  Use it to guard later edits to that buffer. Detached and staged snapshots
  are supplied by the extension; reading this value does not consult Git or
  the filesystem to validate them.

  A nil snapshot means the file did not exist in that source. It is distinct from an empty file.
  """

  alias MingaEditor.Extension.GitDiff.Hunk
  alias MingaEditor.Extension.GitDiff.Origin

  @enforce_keys [:origin, :layout, :contents]
  defstruct [:origin, :layout, :contents, :source_version, :hunk]

  @type layout :: :unified | :side_by_side
  @type contents :: {binary() | nil, binary() | nil}

  @type t :: %__MODULE__{
          origin: Origin.t(),
          layout: layout(),
          contents: contents(),
          source_version: non_neg_integer() | nil,
          hunk: Hunk.t() | nil
        }
end
