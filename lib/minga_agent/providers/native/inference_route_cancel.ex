defmodule MingaAgent.Providers.Native.InferenceRouteCancel do
  @moduledoc """
  Runs a route's `Response.cancel` exactly once when Minga abandons its stream.

  A small unlinked watcher monitors the process consuming the stream. It runs the route's cancel when Minga stops reading early, or when the consumer exits first (an aborted turn, a crash, or `Task.shutdown/2`). It stops without cancelling when the stream finishes, including a finish with an error. A cancel that raises or exits is logged and never crashes Minga.
  """

  @typedoc "Watcher for one route stream."
  @type t :: pid()

  @doc "Starts a watcher for `consumer` that guards the route's cancel function."
  @spec start(pid(), (-> term()), String.t()) :: t()
  def start(consumer, cancel, route_id)
      when is_pid(consumer) and is_function(cancel, 0) and is_binary(route_id) do
    spawn(fn ->
      monitor = Process.monitor(consumer)
      await(monitor, consumer, cancel, route_id)
    end)
  end

  @doc "Asks the watcher to cancel the route stream now."
  @spec cancel(t()) :: :ok
  def cancel(watcher) when is_pid(watcher) do
    send(watcher, :cancel)
    :ok
  end

  @doc "Tells the watcher the stream finished, so the route is never cancelled."
  @spec disarm(t()) :: :ok
  def disarm(watcher) when is_pid(watcher) do
    send(watcher, :finished)
    :ok
  end

  @spec await(reference(), pid(), (-> term()), String.t()) :: :ok
  defp await(monitor, consumer, cancel, route_id) do
    receive do
      :finished -> :ok
      :cancel -> run(cancel, route_id)
      {:DOWN, ^monitor, :process, ^consumer, _reason} -> run(cancel, route_id)
    end
  end

  @spec run((-> term()), String.t()) :: :ok
  defp run(cancel, route_id) do
    cancel.()
    :ok
  rescue
    exception -> report(route_id, {:raised, Exception.message(exception)})
  catch
    kind, reason -> report(route_id, {kind, reason})
  end

  @spec report(String.t(), term()) :: :ok
  defp report(route_id, failure) do
    Minga.Log.warning(
      :agent,
      "Model route #{route_id} failed while cancelling a stream: #{MingaAgent.Redaction.format_error(failure)}"
    )
  end
end
