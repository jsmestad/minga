defmodule Minga.Test.Storyboard.ParserRelay do
  @moduledoc """
  Forwards one storyboard session's buffer edits to the shared parser.

  `Minga.Parser.Manager` learns that a buffer changed from `:buffer_changed` events on the one events registry it subscribed to at start. Every storyboard session keeps its own private registry, so concurrent sessions never see each other's events, which means the shared parser would never hear about an edit and its highlights would go stale. The relay subscribes to the session's registry and hands each event to the parser exactly as the registry would.
  """

  use GenServer

  @typedoc "Start options: the session's events registry and the parser to forward to."
  @type option :: {:registry, Minga.Events.registry()} | {:parser, GenServer.server()}

  @doc "Starts a relay for one session."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    :ok = Minga.Events.subscribe(:buffer_changed, Keyword.fetch!(opts, :registry))
    {:ok, Keyword.fetch!(opts, :parser)}
  end

  @impl true
  def handle_info({:minga_event, :buffer_changed, _payload} = event, parser) do
    case GenServer.whereis(parser) do
      nil -> :ok
      pid -> send(pid, event)
    end

    {:noreply, parser}
  end

  def handle_info(_message, parser), do: {:noreply, parser}
end
