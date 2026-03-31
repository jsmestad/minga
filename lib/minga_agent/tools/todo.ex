defmodule MingaAgent.Tools.Todo do
  @moduledoc """
  Task list tools for multi-step progress tracking within agent turns.

  The agent creates a plan with `todo_write`, checks items off as it
  completes them, and reviews remaining work with `todo_read`. The
  checklist persists across tool-calling loops within a single prompt.
  """

  alias MingaAgent.InternalState

  @doc """
  Writes (replaces) the task list. Each item should have a description
  and status (pending, in_progress, done).
  """
  @spec write(pid(), [map()]) :: {:ok, String.t()}
  def write(provider_pid, items) when is_pid(provider_pid) and is_list(items) do
    :ok =
      GenServer.call(
        provider_pid,
        {:update_internal_state,
         fn state ->
           InternalState.write_todos(state, items)
         end}
      )

    {:ok, internal_state} = GenServer.call(provider_pid, :get_internal_state)
    {:ok, "Task list updated.\n\n" <> InternalState.read_todos(internal_state)}
  end

  @doc "Returns the current task list."
  @spec read(pid()) :: {:ok, String.t()}
  def read(provider_pid) when is_pid(provider_pid) do
    {:ok, internal_state} = GenServer.call(provider_pid, :get_internal_state)
    {:ok, InternalState.read_todos(internal_state)}
  end
end
