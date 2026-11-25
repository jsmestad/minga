defmodule MingaEditor.Agent.Activity do
  @moduledoc """
  Turn-scoped activity projection for the agent UI.

  The provider owns the underlying tool and todo state. This struct is the editor's
  render projection: it records the current turn start time, latest visible todo
  plan, active action, tool count, and touched file set.
  """

  alias MingaAgent.TodoItem
  alias MingaEditor.Agent.TaskFiles
  alias MingaAgent.Session.TurnExecution

  @type t :: %__MODULE__{
          todos: [TodoItem.t()],
          started_at: DateTime.t() | nil,
          active_action: String.t(),
          tool_count: non_neg_integer(),
          running_tools: %{String.t() => {pos_integer(), String.t()}},
          active_tool_id: String.t() | nil,
          file_paths: MapSet.t(String.t()),
          task_files: TaskFiles.t()
        }

  defstruct todos: [],
            started_at: nil,
            active_action: "",
            tool_count: 0,
            running_tools: %{},
            active_tool_id: nil,
            file_paths: MapSet.new(),
            task_files: TaskFiles.new()

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
    %{activity | active_action: "", started_at: nil, running_tools: %{}, active_tool_id: nil}
  end

  @doc "Applies a Session status to the turn: a working status starts it, idle finishes it, and an error or plan finishes it unless a tool still runs."
  @spec apply_status(t(), TurnExecution.display_status()) :: t()
  def apply_status(%__MODULE__{} = activity, status) when status in [:thinking, :tool_executing],
    do: start_turn(activity)

  def apply_status(%__MODULE__{} = activity, status) when status in [:idle, :stopped],
    do: finish_turn(activity)

  def apply_status(%__MODULE__{active_tool_id: nil} = activity, status)
      when status in [:error, :plan],
      do: finish_turn(activity)

  def apply_status(%__MODULE__{} = activity, _status), do: activity

  @doc "Seeds the first visible timestamp without resetting the turn state."
  @spec ensure_started_at(t()) :: t()
  def ensure_started_at(%__MODULE__{started_at: nil} = activity) do
    %{activity | started_at: DateTime.utc_now()}
  end

  def ensure_started_at(%__MODULE__{} = activity), do: activity

  @doc "Replaces the visible todo plan."
  @spec set_todos(t(), [TodoItem.t()]) :: t()
  def set_todos(%__MODULE__{} = activity, todos) when is_list(todos) do
    %{activity | todos: todos}
  end

  @doc "Records the identity and start order of a running tool."
  @spec start_tool(t(), String.t(), String.t()) :: t()
  def start_tool(%__MODULE__{running_tools: tools} = activity, id, name) do
    case tools do
      %{^id => _known} ->
        activity

      %{} ->
        activity = start_turn(activity)
        count = activity.tool_count + 1

        %{
          activity
          | running_tools: Map.put(tools, id, {count, name}),
            active_tool_id: id,
            tool_count: count,
            active_action: action(name)
        }
    end
  end

  @doc "Retires only the finished or interrupted call."
  @spec finish_tool(t(), String.t()) :: t()
  def finish_tool(%__MODULE__{running_tools: tools} = activity, id) do
    case Map.pop(tools, id) do
      {nil, _tools} ->
        activity

      {_tool, tools} when id == activity.active_tool_id ->
        project_tools(activity, tools)

      {_tool, tools} ->
        %{activity | running_tools: tools}
    end
  end

  @doc "Hydrates the active tool projection from the Session's ordered snapshot."
  @spec restore_running_tools(t(), [TurnExecution.active_tool()]) :: t()
  def restore_running_tools(%__MODULE__{} = activity, []) do
    case activity.running_tools do
      tools when map_size(tools) == 0 -> activity
      _tools -> project_tools(activity, %{})
    end
  end

  def restore_running_tools(%__MODULE__{} = activity, tools) do
    {running_tools, count} =
      Enum.reduce(tools, {%{}, 0}, fn {id, name}, {running_tools, count} ->
        index = count + 1
        {Map.put(running_tools, id, {index, name}), index}
      end)

    activity = ensure_started_at(activity)
    project_tools(%{activity | tool_count: max(count, activity.tool_count)}, running_tools)
  end

  @doc "Returns the most recently started tool that has not ended."
  @spec active_tool_name(t()) :: String.t() | nil
  def active_tool_name(%__MODULE__{active_tool_id: nil}), do: nil

  def active_tool_name(%__MODULE__{active_tool_id: id, running_tools: tools}) do
    {_order, name} = Map.fetch!(tools, id)
    name
  end

  @doc """
  Records a file the task's tools changed: once for the current turn's file count, and in the task's ordered files.

  `author` names the task (`Minga.Buffer.Author.minga/1`), or nil when it is not known yet. `identity` is the file's `Minga.Buffer.file_identity/1`. The task's files outlive the turn, so the modeline can say which file Minga is editing between turns.
  """
  @spec record_file(t(), Minga.Buffer.Author.t() | nil, String.t(), String.t()) :: t()
  def record_file(%__MODULE__{} = activity, author, path, identity)
      when is_binary(path) and is_binary(identity) do
    %{
      activity
      | file_paths: MapSet.put(activity.file_paths, path),
        task_files: TaskFiles.record(activity.task_files, author, path, identity)
    }
  end

  @doc "The file `author`'s task edited last, as `{identity, path}`, or nil before its first edit."
  @spec current_file(t(), Minga.Buffer.Author.t() | nil) :: TaskFiles.entry() | nil
  def current_file(%__MODULE__{task_files: files}, author), do: TaskFiles.current(files, author)

  @doc "The author of task `task_id`'s edits, or nil for a task not known yet."
  @spec task_author(String.t() | nil) :: Minga.Buffer.Author.t() | nil
  def task_author(nil), do: nil
  def task_author(task_id) when is_binary(task_id), do: Minga.Buffer.Author.minga(task_id)

  @doc """
  How far through its visible plan Minga is, as `{step, steps}`, or nil without a plan.

  The step is the last one Minga has reached: every done item, plus the one in progress or blocked.
  """
  @spec progress(t()) :: {non_neg_integer(), pos_integer()} | nil
  def progress(%__MODULE__{todos: []}), do: nil

  def progress(%__MODULE__{todos: todos}) do
    {Enum.count(todos, &(&1.status != :pending)), Enum.count(todos)}
  end

  @doc "Returns the number of touched files in the current projection."
  @spec file_count(t()) :: non_neg_integer()
  def file_count(%__MODULE__{} = activity), do: MapSet.size(activity.file_paths)

  @spec project_tools(t(), %{String.t() => {pos_integer(), String.t()}}) :: t()
  defp project_tools(activity, running_tools) do
    {id, {_order, name}} =
      Enum.max_by(running_tools, fn {_id, {order, _name}} -> order end, fn -> {nil, {0, nil}} end)

    %{activity | running_tools: running_tools, active_tool_id: id, active_action: action(name)}
  end

  @spec action(String.t() | nil) :: String.t()
  defp action(nil), do: "Thinking"
  defp action(name), do: "Running #{name}"
end
