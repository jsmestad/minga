defmodule MingaEditor.Agent.Activity do
  @moduledoc """
  Turn-scoped activity projection for the agent UI.

  The provider owns the underlying tool and todo state. This struct is the editor's
  render projection: it records the current turn start time, latest visible todo
  plan, active action, tool count, and touched file set.
  """

  alias MingaAgent.TodoItem

  @type t :: %__MODULE__{
          todos: [TodoItem.t()],
          started_at: DateTime.t() | nil,
          active_action: String.t(),
          tool_count: non_neg_integer(),
          file_paths: MapSet.t(String.t())
        }

  defstruct todos: [],
            started_at: nil,
            active_action: "",
            tool_count: 0,
            file_paths: MapSet.new()

  @doc "Creates an empty activity projection."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Marks the beginning of a turn, preserving the visible plan."
  @spec start_turn(t()) :: t()
  def start_turn(%__MODULE__{} = activity) do
    start_turn(activity, DateTime.utc_now())
  end

  @doc "Marks the beginning of a turn with a caller-provided timestamp."
  @spec start_turn(t(), DateTime.t()) :: t()
  def start_turn(%__MODULE__{started_at: nil} = activity, %DateTime{} = now) do
    %{
      activity
      | started_at: now,
        active_action: "Thinking",
        tool_count: 0,
        file_paths: MapSet.new()
    }
  end

  def start_turn(%__MODULE__{} = activity, %DateTime{}), do: activity

  @doc "Marks the turn idle while preserving the last visible summary."
  @spec finish_turn(t()) :: t()
  def finish_turn(%__MODULE__{} = activity) do
    %{activity | active_action: "", started_at: nil}
  end

  @doc "Replaces the visible todo plan."
  @spec set_todos(t(), [TodoItem.t()]) :: t()
  def set_todos(%__MODULE__{} = activity, todos) when is_list(todos) do
    %{activity | todos: todos}
  end

  @doc "Records that a tool started running."
  @spec start_tool(t(), String.t()) :: t()
  def start_tool(%__MODULE__{} = activity, tool_name) when is_binary(tool_name) do
    activity
    |> start_turn()
    |> put_tool(tool_name)
  end

  @doc "Clears the active action after a tool finishes."
  @spec finish_tool(t()) :: t()
  def finish_tool(%__MODULE__{} = activity) do
    %{activity | active_action: "Thinking"}
  end

  @doc "Records a touched file path for the current turn."
  @spec record_file(t(), String.t()) :: t()
  def record_file(%__MODULE__{} = activity, path) when is_binary(path) do
    %{activity | file_paths: MapSet.put(activity.file_paths, path)}
  end

  @doc "Returns the number of touched files in the current projection."
  @spec file_count(t()) :: non_neg_integer()
  def file_count(%__MODULE__{} = activity), do: MapSet.size(activity.file_paths)

  @spec put_tool(t(), String.t()) :: t()
  defp put_tool(%__MODULE__{} = activity, tool_name) do
    %{activity | active_action: "Running #{tool_name}", tool_count: activity.tool_count + 1}
  end
end
