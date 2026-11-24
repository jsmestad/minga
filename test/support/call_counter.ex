defmodule Minga.Test.CallCounter do
  @moduledoc """
  Counts calls to one function made while another function runs.

  `count/2` runs the function in a fresh worker process and traces only that worker, because a process cannot be its own tracer. It uses an isolated trace session, so concurrent tests that trace other processes or functions neither see these trace messages nor disturb the count. Calls made by any other process, including processes the function starts, are not counted.
  """

  @doc "Runs `fun` in a traced worker and returns how many times the worker called `mfa`, with the result of `fun`."
  @spec count(mfa(), (-> result)) :: {non_neg_integer(), result} when result: term()
  def count({module, function, arity} = mfa, fun)
      when is_atom(module) and is_atom(function) and is_integer(arity) and is_function(fun, 0) do
    Code.ensure_loaded!(module)
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run -> send(parent, {__MODULE__, self(), fun.()})
        end

        receive do
          :stop -> :ok
        end
      end)

    session = :trace.session_create(__MODULE__, parent, [])

    try do
      1 = :trace.function(session, mfa, true, [:global])
      1 = :trace.process(session, worker, true, [:call])
      send(worker, :run)
      result = await_result(worker, monitor)
      await_delivery(worker)
      send(worker, :stop)
      {drain(worker, mfa, 0), result}
    after
      :trace.session_destroy(session)
      Process.demonitor(monitor, [:flush])
    end
  end

  @spec await_result(pid(), reference()) :: term()
  defp await_result(worker, monitor) do
    receive do
      {__MODULE__, ^worker, result} -> result
      {:DOWN, ^monitor, :process, ^worker, reason} -> exit(reason)
    end
  end

  @spec await_delivery(pid()) :: :ok
  defp await_delivery(worker) do
    ref = :erlang.trace_delivered(worker)

    receive do
      {:trace_delivered, ^worker, ^ref} -> :ok
    end
  end

  @spec drain(pid(), mfa(), non_neg_integer()) :: non_neg_integer()
  defp drain(worker, {module, function, arity} = mfa, count) do
    receive do
      {:trace, ^worker, :call, {^module, ^function, args}} when length(args) == arity ->
        drain(worker, mfa, count + 1)
    after
      0 -> count
    end
  end
end
