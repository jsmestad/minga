defmodule MingaAgent.Branch do
  @moduledoc """
  An immutable snapshot of identified transcript entries.

  Branch creation and switching are aggregate transcript transitions owned by
  `MingaAgent.Session.Transcript`. This value stores only the frozen snapshot
  and its presentation metadata.
  """

  alias MingaAgent.TranscriptEntry

  @typedoc "A named conversation branch snapshot."
  @type t :: %__MODULE__{
          name: String.t(),
          entries: [TranscriptEntry.t()],
          created_at: DateTime.t()
        }

  @enforce_keys [:name, :entries, :created_at]
  defstruct [:name, :entries, :created_at]

  @doc "Creates a branch snapshot from identified entries."
  @spec new(String.t(), [TranscriptEntry.t()], DateTime.t()) :: t()
  def new(name, entries, %DateTime{} = created_at) when is_binary(name) and is_list(entries) do
    %__MODULE__{name: name, entries: entries, created_at: created_at}
  end

  @doc "Returns the branch messages in transcript order."
  @spec messages(t()) :: [MingaAgent.Message.t()]
  def messages(%__MODULE__{} = branch), do: Enum.map(branch.entries, & &1.message)

  @doc "Returns the stable entry IDs in branch order."
  @spec entry_ids(t()) :: [pos_integer()]
  def entry_ids(%__MODULE__{} = branch), do: Enum.map(branch.entries, & &1.id)

  @doc "Lists branches with their names and message counts."
  @spec list([t()]) :: String.t()
  def list([]), do: "No branches. Use /branch <turn_number> to create one."

  def list(branches) do
    branches
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {branch, index} ->
      time = Calendar.strftime(branch.created_at, "%H:%M:%S UTC")
      "  #{index}. #{branch.name} (#{Enum.count(branch.entries)} messages, created #{time})"
    end)
  end
end
