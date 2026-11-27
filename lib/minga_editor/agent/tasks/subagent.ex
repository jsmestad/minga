defmodule MingaEditor.Agent.Tasks.Subagent do
  @moduledoc """
  A foreground subagent a task started with its `subagent` tool, shown beneath the task in the tasks drawer.

  The parent's tool events report handback, independent of how long the child Session stays open. Background subagents are tracked as separate tasks.
  """

  alias MingaAgent.Event.ToolEnd
  alias MingaAgent.Event.ToolStart
  alias MingaAgent.Tool.Invocation

  @typedoc "The state a subagent shows."
  @type state :: :working | :done | :failed | :stopped
  @type reports :: {received :: pos_integer(), started :: pos_integer()}

  @type t :: %__MODULE__{
          id: String.t(),
          invocation_key: Invocation.key() | nil,
          entry_id: pos_integer() | nil,
          title: String.t(),
          brief: String.t(),
          state: state(),
          started_at: integer(),
          changed_at: integer(),
          result: String.t() | nil,
          reports: reports() | nil
        }

  @enforce_keys [:id, :title, :state, :started_at, :changed_at]
  defstruct @enforce_keys ++ [:invocation_key, :entry_id, :result, :reports, brief: ""]

  @tool "subagent"

  @doc "Adds the subagent a `subagent` tool call started. Other tools and background calls leave the list unchanged."
  @spec started([t()], ToolStart.t(), integer()) :: [t()]
  def started(subagents, %ToolStart{name: @tool, args: args} = event, now) do
    cond do
      Map.get(args, "background") == true -> subagents
      Enum.any?(subagents, &matches?(&1, event.tool_call_id, event.invocation_key)) -> subagents
      true -> subagents ++ [new(event, now)]
    end
  end

  def started(subagents, %ToolStart{}, _now), do: subagents

  @doc "Settles the subagent whose tool call ended."
  @spec ended([t()], ToolEnd.t(), integer()) :: [t()]
  def ended(subagents, %ToolEnd{name: @tool} = event, now) do
    status = ended_state(event.outcome, event.is_error)

    case Enum.find(subagents, &matches?(&1, event.tool_call_id, event.invocation_key)) do
      %__MODULE__{state: :working} = original ->
        reported = %{
          original
          | state: status,
            changed_at: now,
            result: event.result,
            reports: reports_at_handback(subagents, original.invocation_key, status)
        }

        Enum.map(subagents, fn
          ^original -> reported
          other -> other
        end)

      _unmatched_or_terminal ->
        subagents
    end
  end

  def ended(subagents, %ToolEnd{}, _now), do: subagents

  @doc "Lists the foreground calls issued in the same fan-out, in their tool order."
  @spec siblings([t()], Invocation.key()) :: [t()]
  def siblings(subagents, {request, checkpoint, _call}) do
    Enum.filter(subagents, &match?({^request, ^checkpoint, _}, &1.invocation_key))
  end

  @doc "Returns the opaque frontend activation token for the exact invocation."
  @spec action_token(MingaAgent.SessionManager.foreground_identity()) :: String.t()
  def action_token({_parent, {_request, _checkpoint, _call}} = identity),
    do: Base.url_encode64(:erlang.term_to_binary(identity), padding: false)

  @doc "Stops the subagent whose tool call was interrupted."
  @spec interrupted([t()], String.t(), integer()) :: [t()]
  def interrupted(subagents, id, now) do
    Enum.map(subagents, fn
      %__MODULE__{id: ^id, state: :working} = subagent ->
        %{subagent | state: :stopped, changed_at: now}

      subagent ->
        subagent
    end)
  end

  @doc "Stops every subagent still running, when the task's session ended under them."
  @spec stop_running([t()], integer()) :: [t()]
  def stop_running(subagents, now) do
    Enum.map(subagents, fn
      %__MODULE__{state: :working} = subagent -> %{subagent | state: :stopped, changed_at: now}
      subagent -> subagent
    end)
  end

  @spec new(ToolStart.t(), integer()) :: t()
  defp new(event, now) do
    brief = brief(event.args)

    %__MODULE__{
      id: event.tool_call_id,
      invocation_key: event.invocation_key,
      entry_id: event.entry_id,
      title: title(brief),
      brief: brief,
      state: :working,
      started_at: now,
      changed_at: now
    }
  end

  @spec reports_at_handback([t()], Invocation.key() | nil, state()) :: reports() | nil
  defp reports_at_handback(subagents, {request, checkpoint, _call}, :done) do
    Enum.reduce(subagents, {1, 0}, fn
      %__MODULE__{invocation_key: {^request, ^checkpoint, _}, state: :done},
      {received, started} ->
        {received + 1, started + 1}

      %__MODULE__{invocation_key: {^request, ^checkpoint, _}}, {received, started} ->
        {received, started + 1}

      _unrelated, counts ->
        counts
    end)
  end

  defp reports_at_handback(_subagents, _key, _status), do: nil

  @spec matches?(t(), String.t(), Invocation.key() | nil) :: boolean()
  defp matches?(subagent, id, key), do: subagent.id == id and subagent.invocation_key == key

  @spec ended_state(MingaAgent.ToolCall.outcome(), boolean()) :: state()
  defp ended_state(:complete, false), do: :done
  defp ended_state(:cancelled, _error?), do: :stopped
  defp ended_state(_outcome, _error?), do: :failed

  @spec brief(map()) :: String.t()
  defp brief(%{"task" => task}) when is_binary(task), do: task
  defp brief(_args), do: ""

  @spec title(String.t()) :: String.t()
  defp title(task) do
    case task |> String.split("\n", parts: 2) |> hd() |> String.trim() do
      "" -> "Subagent"
      line -> line
    end
  end
end
