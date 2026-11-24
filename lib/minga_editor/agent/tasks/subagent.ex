defmodule MingaEditor.Agent.Tasks.Subagent do
  @moduledoc """
  A foreground subagent a task started with its `subagent` tool, shown beneath the task in the tasks drawer.

  The parent's tool events are its only source: the call's start names it, and the call's end says whether it is done or failed. A background subagent returns from its tool call at once and runs as a session of its own, so it is tracked as a separate task, not here.
  """

  alias MingaAgent.Event.ToolEnd

  @typedoc "The state a subagent shows."
  @type state :: :working | :done | :failed | :stopped

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          state: state(),
          started_at: integer(),
          changed_at: integer()
        }

  @enforce_keys [:id, :title, :state, :started_at, :changed_at]
  defstruct [:id, :title, :state, :started_at, :changed_at]

  @tool "subagent"

  @doc "Adds the subagent a `subagent` tool call started. Other tools and background calls leave the list unchanged."
  @spec started([t()], String.t(), String.t(), map(), integer()) :: [t()]
  def started(subagents, id, @tool, %{} = args, now) when is_binary(id) do
    cond do
      Map.get(args, "background") == true -> subagents
      Enum.any?(subagents, &(&1.id == id)) -> subagents
      true -> subagents ++ [new(id, args, now)]
    end
  end

  def started(subagents, _id, _name, _args, _now), do: subagents

  @doc "Settles the subagent whose tool call ended."
  @spec ended([t()], ToolEnd.t(), integer()) :: [t()]
  def ended(subagents, %ToolEnd{tool_call_id: id, outcome: outcome, is_error: error?}, now),
    do: settle(subagents, id, ended_state(outcome, error?), now)

  @doc "Stops the subagent whose tool call was interrupted."
  @spec interrupted([t()], String.t(), integer()) :: [t()]
  def interrupted(subagents, id, now), do: settle(subagents, id, :stopped, now)

  @doc "Stops every subagent still running, when the task's session ended under them."
  @spec stop_running([t()], integer()) :: [t()]
  def stop_running(subagents, now) do
    Enum.map(subagents, fn
      %__MODULE__{state: :working} = subagent -> %{subagent | state: :stopped, changed_at: now}
      subagent -> subagent
    end)
  end

  @spec new(String.t(), map(), integer()) :: t()
  defp new(id, args, now) do
    %__MODULE__{
      id: id,
      title: title(args),
      state: :working,
      started_at: now,
      changed_at: now
    }
  end

  @spec settle([t()], String.t(), state(), integer()) :: [t()]
  defp settle(subagents, id, state, now) do
    Enum.map(subagents, fn
      %__MODULE__{id: ^id, state: :working} = subagent ->
        %{subagent | state: state, changed_at: now}

      subagent ->
        subagent
    end)
  end

  @spec ended_state(MingaAgent.ToolCall.outcome(), boolean()) :: state()
  defp ended_state(:complete, false), do: :done
  defp ended_state(:cancelled, _error?), do: :stopped
  defp ended_state(_outcome, _error?), do: :failed

  @spec title(map()) :: String.t()
  defp title(%{"task" => task}) when is_binary(task) do
    case task |> String.split("\n", parts: 2) |> hd() |> String.trim() do
      "" -> "Subagent"
      line -> line
    end
  end

  defp title(_args), do: "Subagent"
end
