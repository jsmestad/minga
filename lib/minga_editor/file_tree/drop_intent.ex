defmodule MingaEditor.FileTree.DropIntent do
  @moduledoc """
  BEAM-owned file-tree drop intent sent by native GUI frontends.

  The frontend reports what the user tried to do. The BEAM validates the target row against current file-tree state and performs the filesystem operation.
  """

  @enforce_keys [
    :source_paths,
    :target_index,
    :target_id,
    :target_path_hash,
    :target_path,
    :target_dir?,
    :modifiers
  ]
  defstruct source_paths: [],
            target_index: 0,
            target_id: "",
            target_path_hash: 0,
            target_path: "",
            target_dir?: false,
            modifiers: 0

  @type t :: %__MODULE__{
          source_paths: [String.t()],
          target_index: non_neg_integer(),
          target_id: String.t(),
          target_path_hash: non_neg_integer(),
          target_path: String.t(),
          target_dir?: boolean(),
          modifiers: non_neg_integer()
        }

  @doc "Constructs a drop intent from decoded GUI protocol fields."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs), do: struct!(__MODULE__, attrs)
end
