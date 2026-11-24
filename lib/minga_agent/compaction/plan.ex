defmodule MingaAgent.Compaction.Plan do
  @moduledoc """
  Immutable compaction plan over semantic groups.

  The plan partitions a grouped conversation into groups that will be
  summarized (`to_compact`) and groups that will be kept verbatim (`to_keep`).
  System groups are always kept. The most recent N non-system groups are kept.
  Groups are never split.
  """

  alias MingaAgent.Compaction.Group

  @type t :: %__MODULE__{
          to_compact: [Group.t()],
          to_keep: [Group.t()]
        }

  @enforce_keys [:to_compact, :to_keep]
  defstruct @enforce_keys

  @doc "Builds a plan from partitioned groups."
  @spec new([Group.t()], [Group.t()]) :: t()
  def new(to_compact, to_keep) when is_list(to_compact) and is_list(to_keep) do
    %__MODULE__{to_compact: to_compact, to_keep: to_keep}
  end

  @doc "Returns `true` when the plan has groups to compact."
  @spec actionable?(t()) :: boolean()
  def actionable?(%__MODULE__{to_compact: [_ | _]}), do: true
  def actionable?(%__MODULE__{}), do: false

  @doc "Flattens the kept groups into a single message list."
  @spec kept_messages(t()) :: [ReqLLM.Message.t()]
  def kept_messages(%__MODULE__{to_keep: groups}) do
    Enum.flat_map(groups, & &1.messages)
  end

  @doc "Flattens the groups to compact into a single message list."
  @spec compactable_messages(t()) :: [ReqLLM.Message.t()]
  def compactable_messages(%__MODULE__{to_compact: groups}) do
    Enum.flat_map(groups, & &1.messages)
  end
end
