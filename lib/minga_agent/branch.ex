defmodule MingaAgent.Branch do
  @moduledoc """
  Conversation branching for the agent session.

  Allows rewinding to an earlier turn and trying a different prompt,
  creating a branch. Previous branches are preserved and can be revisited.
  This enables "what if" exploration without losing prior work.
  """

  alias MingaAgent.Message

  @typedoc "A named conversation branch."
  @type t :: %__MODULE__{
          name: String.t(),
          messages: [Message.t()],
          created_at: DateTime.t()
        }

  @enforce_keys [:name, :messages, :created_at]
  defstruct [:name, :messages, :created_at]

  @doc "Creates a new branch from the given messages."
  @spec new(String.t(), [Message.t()]) :: t()
  def new(name, messages) when is_binary(name) and is_list(messages) do
    %__MODULE__{
      name: name,
      messages: messages,
      created_at: DateTime.utc_now()
    }
  end

  @doc """
  Branches at the given turn index, saving the current messages
  as a named branch and returning the truncated message list.

  Turn index is 0-based. Messages from index 0 to `turn_index` (inclusive)
  are kept; the rest become the branch.
  """
  @spec branch_at(
          [Message.t()],
          non_neg_integer(),
          String.t(),
          [t()]
        ) :: {:ok, [Message.t()], [t()]} | {:error, String.t()}
  def branch_at(messages, turn_index, branch_name, existing_branches)
      when is_integer(turn_index) and turn_index >= 0 do
    if turn_index >= length(messages) do
      {:error, "Turn index #{turn_index} is beyond the conversation length (#{length(messages)})"}
    else
      # Save current messages as a branch
      branch = new(branch_name, messages)
      branches = existing_branches ++ [branch]

      # Truncate to the branch point
      truncated = Enum.take(messages, turn_index + 1)

      {:ok, truncated, branches}
    end
  end

  @doc "Lists all branches with their names and message counts."
  @spec list([t()]) :: String.t()
  def list([]) do
    "No branches. Use /branch <turn_number> to create one."
  end

  def list(branches) do
    branches
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {b, idx} ->
      time = Calendar.strftime(b.created_at, "%H:%M:%S UTC")
      "  #{idx}. #{b.name} (#{length(b.messages)} messages, created #{time})"
    end)
  end
end
