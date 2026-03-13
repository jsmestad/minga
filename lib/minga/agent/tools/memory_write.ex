defmodule Minga.Agent.Tools.MemoryWrite do
  @moduledoc """
  Appends a learning or preference to the persistent user memory file.

  The agent can call this tool to record useful information across sessions,
  such as user preferences, project conventions, or recurring patterns.

  NOTE: This module is not currently wired into `Tools.all/1`. Memory writes
  happen through the `/remember` slash command which calls `Memory.append/1`
  directly. This module exists as scaffolding for when memory_write is exposed
  as an agent tool. Wire it into `Tools.all/1` or remove it.
  """

  alias Minga.Agent.Memory

  @doc """
  Appends `text` to the persistent memory file with a timestamp.
  """
  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(text) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:error, "Memory text cannot be empty"}
    else
      case Memory.append(text) do
        :ok -> {:ok, "Saved to memory: #{text}"}
        {:error, reason} -> {:error, "Failed to save memory: #{inspect(reason)}"}
      end
    end
  end
end
