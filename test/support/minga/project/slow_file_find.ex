defmodule Minga.Project.SlowFileFind do
  @moduledoc "A controllable file-discovery backend for Project lifecycle tests."

  @spec start(Minga.Project.Root.t(), pid()) :: {:ok, pid()}
  def start(_root, owner) do
    {:ok, spawn(fn -> wait_for_control(owner, Process.monitor(owner)) end)}
  end

  @doc "Completes a controlled discovery with the exact result."
  @spec complete(pid(), Minga.Project.FileFind.result()) :: :ok
  def complete(pid, result) when is_pid(pid) do
    send(pid, {:complete, result})
    :ok
  end

  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    send(pid, :cancel)
    :ok
  end

  @spec wait_for_control(pid(), reference()) :: :ok
  defp wait_for_control(owner, owner_ref) do
    receive do
      {:complete, result} ->
        send(owner, {:file_find_done, self(), result})
        :ok

      :cancel ->
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok
    end
  end
end
