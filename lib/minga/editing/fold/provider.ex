defmodule Minga.Editing.Fold.Provider do
  @moduledoc """
  Behaviour for fold range providers.

  A fold provider computes the list of foldable ranges for a buffer.
  Two built-in providers exist:

  - `Minga.Editing.Fold.TreeSitterProvider` — uses tree-sitter `folds.scm` queries
  - Extensions can implement this behaviour for custom folding (e.g., org headings)

  Providers register themselves via `Minga.Editing.Fold.Registry` at startup.
  The editor queries the registry when a buffer opens or changes filetype
  to find the appropriate provider.
  """

  alias Minga.Editor.FoldRange

  @doc """
  Returns the list of filetypes this provider handles.

  Return `:all` to handle every filetype (e.g., tree-sitter provider
  handles any filetype with a `folds.scm` query).
  """
  @callback filetypes() :: [atom()] | :all

  @doc """
  Computes fold ranges for a buffer.

  `buffer` is the Buffer.Server pid. `filetype` is the buffer's filetype atom.
  The provider should read the buffer content and return a list of fold ranges.

  This callback may be called from any process. Implementations should
  not store state; they should compute ranges from the buffer's current
  content each time.
  """
  @callback fold_ranges(buffer :: pid(), filetype :: atom()) :: [FoldRange.t()]
end
