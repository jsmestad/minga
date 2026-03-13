defmodule Minga.Agent.Tools.Notebook do
  @moduledoc """
  Scratchpad tools for internal planning and state tracking.

  The agent writes notes, plans, and intermediate reasoning to a scratchpad
  that persists across tool-calling turns but is not shown to the user in
  the chat. Content is cleared on new user prompts.
  """

  alias Minga.Agent.InternalState

  @doc "Writes (replaces) the notebook content."
  @spec write(pid(), String.t()) :: {:ok, String.t()}
  def write(provider_pid, content) when is_pid(provider_pid) and is_binary(content) do
    :ok =
      GenServer.call(
        provider_pid,
        {:update_internal_state,
         fn state ->
           InternalState.write_notebook(state, content)
         end}
      )

    {:ok, "Notebook updated (#{String.length(content)} chars)."}
  end

  @doc "Returns the current notebook content."
  @spec read(pid()) :: {:ok, String.t()}
  def read(provider_pid) when is_pid(provider_pid) do
    {:ok, internal_state} = GenServer.call(provider_pid, :get_internal_state)
    {:ok, InternalState.read_notebook(internal_state)}
  end
end
