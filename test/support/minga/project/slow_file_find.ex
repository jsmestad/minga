defmodule Minga.Project.SlowFileFind do
  @moduledoc "A controllable file-discovery backend for Project lifecycle tests."

  @spec start(Minga.Project.Root.t(), pid()) :: {:ok, pid()}
  def start(_root, owner) do
    {:ok, spawn(fn -> wait_for_cancel(owner, Process.monitor(owner)) end)}
  end

  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    send(pid, :cancel)
    :ok
  end

  @spec wait_for_cancel(pid(), reference()) :: :ok
  defp wait_for_cancel(owner, owner_ref) do
    receive do
      :cancel -> :ok
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
    end
  end
end
