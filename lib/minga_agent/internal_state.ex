defmodule MingaAgent.InternalState do
  @moduledoc """
  Volatile Native provider state for the task checklist.

  The provider owns the checklist while it is running. It is not part of the saved conversation.
  """

  alias MingaAgent.TodoItem

  @typedoc "Status of a todo item."
  @type todo_status :: TodoItem.status()

  @typedoc "A single todo item."
  @type todo_item :: TodoItem.t()

  @typedoc "The full internal state."
  @type t :: %__MODULE__{todos: [todo_item()]}

  defstruct todos: []

  @doc "Creates a new empty internal state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Todo operations ─────────────────────────────────────────────────────────

  @doc """
  Writes (replaces) the entire todo list.

  Each item should have `description` and `status` keys.
  Missing statuses default to `:pending`.
  """
  @spec write_todos(t(), [map()]) :: t()
  def write_todos(%__MODULE__{} = state, items) when is_list(items) do
    todos =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        %TodoItem{
          id: Map.get(item, "id", "task_#{index + 1}"),
          description: Map.get(item, "description", ""),
          status: parse_status(Map.get(item, "status", "pending"))
        }
      end)

    %{state | todos: todos}
  end

  @doc "Returns the current todo list as a formatted string."
  @spec read_todos(t()) :: String.t()
  def read_todos(%__MODULE__{todos: []}) do
    "No tasks. Use todo_write to create a task list."
  end

  def read_todos(%__MODULE__{todos: todos}) do
    todos
    |> Enum.map_join("\n", fn item ->
      icon =
        case item.status do
          :done -> "✅"
          :in_progress -> "🔄"
          :pending -> "⬜"
        end

      "#{icon} [#{item.id}] #{item.description} (#{item.status})"
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec parse_status(String.t() | atom()) :: todo_status()
  defp parse_status(:pending), do: :pending
  defp parse_status(:in_progress), do: :in_progress
  defp parse_status(:done), do: :done
  defp parse_status("pending"), do: :pending
  defp parse_status("in_progress"), do: :in_progress
  defp parse_status("done"), do: :done
  defp parse_status(_), do: :pending
end
