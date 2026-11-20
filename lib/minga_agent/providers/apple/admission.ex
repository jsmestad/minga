defmodule MingaAgent.Providers.Apple.Admission do
  @moduledoc "Keeps the Apple Port owner responsive while the session assesses its held request."

  @type result :: :ok | :canceled | :timed_out | {:error, term()}

  @doc "Releases the held Port request only while authorization and the stream are current."
  @spec release(port(), (-> :ok | {:error, term()}), reference(), reference(), integer()) ::
          result()
  def release(port, authorize, owner, consumer, deadline) do
    case await(authorize, owner, consumer, deadline) do
      :ok -> if Port.command(port, "admit\n"), do: :ok, else: {:error, :apple_helper_unavailable}
      terminal -> terminal
    end
  end

  @spec await((-> :ok | {:error, term()}), reference(), reference(), integer()) :: result()
  defp await(authorize, owner, consumer, deadline) do
    parent = self()
    receipt = make_ref()
    {worker, monitor} = spawn_monitor(fn -> send(parent, {receipt, authorize.()}) end)

    try do
      receive do
        {^receipt, :ok} -> still_waiting(owner, consumer, deadline)
        {^receipt, {:error, _} = error} -> error
        {:DOWN, ^monitor, :process, ^worker, _reason} -> {:error, :session_unavailable}
        {:DOWN, ^owner, :process, _, _} -> :canceled
        {:DOWN, ^consumer, :process, _, _} -> :canceled
        :cancel -> :canceled
      after
        remaining(deadline) -> :timed_out
      end
    after
      Process.exit(worker, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  @spec still_waiting(reference(), reference(), integer()) :: :ok | :canceled | :timed_out
  defp still_waiting(owner, consumer, deadline) do
    receive do
      {:DOWN, ^owner, :process, _, _} -> :canceled
      {:DOWN, ^consumer, :process, _, _} -> :canceled
      :cancel -> :canceled
    after
      0 -> if remaining(deadline) > 0, do: :ok, else: :timed_out
    end
  end

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
