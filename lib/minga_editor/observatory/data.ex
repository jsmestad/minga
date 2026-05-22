defmodule MingaEditor.Observatory.Data do
  @moduledoc """
  Shell-level BEAM Observatory snapshot prepared for GUI protocol emission.
  """

  alias Minga.SystemObserver.TreeNode

  @enforce_keys [:visible, :tree, :samples]
  defstruct [:visible, :tree, :samples]

  @type t :: %__MODULE__{
          visible: boolean(),
          tree: TreeNode.t() | nil,
          samples: [Minga.SystemObserver.process_tree_snapshot()]
        }

  @doc "Builds visible Observatory data from a tree and sample history."
  @spec visible(TreeNode.t() | nil, [Minga.SystemObserver.process_tree_snapshot()]) :: t()
  def visible(tree, samples) when is_list(samples) do
    %__MODULE__{visible: true, tree: tree, samples: samples}
  end

  @doc "Builds a hidden Observatory payload."
  @spec hidden() :: t()
  def hidden do
    %__MODULE__{visible: false, tree: nil, samples: []}
  end
end
