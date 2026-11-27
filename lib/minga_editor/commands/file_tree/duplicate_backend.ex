defmodule MingaEditor.Commands.FileTree.DuplicateBackend do
  @moduledoc """
  Injectable filesystem boundary for copies that claim and fill a destination.

  Duplicate tests configure the boundary with immutable context that travels
  with the effect request. Cleanup is called only after a successful claim.
  """

  @type t :: {module(), context()}
  @type context :: term()
  @type entry_type :: :directory | :file
  @type identity :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type owned_entry :: {String.t(), :directory | :regular | :symlink, identity()}
  @type claim :: {owned_entry(), File.io_device() | nil}
  @type copy_result :: :ok | {:error, term(), String.t(), [owned_entry()]}
  @type cleanup_result :: :ok | {:error, term(), String.t()}

  @callback claim_destination(String.t(), entry_type(), context()) ::
              {:ok, claim()} | {:error, term()}
  @callback copy(String.t(), claim(), context()) :: copy_result()
  @callback cleanup([owned_entry()], context()) :: cleanup_result()
end
