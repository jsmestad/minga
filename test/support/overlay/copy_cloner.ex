defmodule MingaAgent.Test.Overlay.CopyCloner do
  @moduledoc """
  Test cloner that copies the tree in Elixir, so async tests exercise the clone path without spawning the `minga-clone-tree` helper.

  Production cloners never copy bytes; this stub only stands in for a copy-on-write clone, which a test cannot tell apart from a copy.
  """

  @behaviour MingaAgent.Changeset.Overlay.Cloner

  @impl true
  @spec clone(String.t(), String.t()) :: :ok | {:error, term()}
  def clone(source, target) do
    case File.cp_r(source, target) do
      {:ok, _files} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @impl true
  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end
end
