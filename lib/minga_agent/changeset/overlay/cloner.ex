defmodule MingaAgent.Changeset.Overlay.Cloner do
  @moduledoc """
  Copy-on-write cloning of a project directory tree into an overlay.

  An overlay clones installed JavaScript packages so a command that writes inside one changes only the overlay. A clone shares its data blocks with the source until either side writes, so cloning a large `node_modules` costs metadata, not bytes. An implementation must fail rather than fall back to a byte-for-byte copy: the overlay then links the packages instead.

  `MingaAgent.Changeset.Overlay` picks the implementation from the `:overlay_cloner` application environment, defaulting to `MingaAgent.Changeset.Overlay.SystemCloner`.
  """

  @typedoc "Why a tree could not be cloned."
  @type error :: term()

  @doc """
  Clones `source` (a file, directory, or symlink) to `target`, which must not exist yet.

  Symlinks inside the tree are copied as links, not followed. On `{:error, reason}`, `target` may hold a partial clone that the caller removes.
  """
  @callback clone(source :: String.t(), target :: String.t()) :: :ok | {:error, error()}

  @doc """
  Removes a directory tree, such as a discarded overlay, without following links inside it.

  A cloned `node_modules` holds tens of thousands of entries, so implementations remove it in one pass rather than entry by entry through the BEAM's file server.
  """
  @callback remove(path :: String.t()) :: :ok | {:error, error()}
end
