defmodule MingaAgent.Tools.MemoryWrite do
  @moduledoc """
  Appends a learning or preference to the persistent user memory file.

  The agent can call this tool to record useful information across sessions,
  such as user preferences, project conventions, or recurring patterns.
  Also available to users via the `/remember` slash command.
  """

  alias MingaAgent.Memory

  @doc """
  Appends `text` to the persistent memory file with a timestamp.
  """
  @spec execute(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def execute(text, config_dir \\ nil) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:error, "Memory text cannot be empty"}
    else
      case Memory.append(text, config_dir) do
        :ok -> {:ok, "Saved to memory: #{text}"}
        {:error, reason} -> {:error, "Failed to save memory: #{inspect(reason)}"}
      end
    end
  end
end
