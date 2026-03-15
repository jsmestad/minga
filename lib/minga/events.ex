defmodule Minga.Events do
  @moduledoc """
  Internal event bus for cross-component notifications.

  Wraps an Elixir `Registry` in `:duplicate` mode so multiple processes
  can subscribe to the same topic and receive broadcasts without knowing
  about each other. The Editor (or any event source) calls `broadcast/2`;
  subscribers receive the payload in `Registry.dispatch/3` callbacks.

  ## Usage

      # In a subscriber (GenServer init, or any long-lived process):
      Minga.Events.subscribe(:buffer_saved)

      # In an event source:
      Minga.Events.broadcast(:buffer_saved, %{buffer: buf, path: path})

  Subscribers receive the event synchronously in the dispatch callback,
  which runs in the broadcaster's process. For heavy work, subscribers
  should send themselves a message and handle it asynchronously.

  ## Why Registry?

  `Registry` ships with OTP (no dependencies), supports pattern-based
  dispatch, and has zero overhead for topics with no subscribers. It is
  the same primitive that Phoenix.PubSub builds on, without the Phoenix
  dependency. The wrapper module makes swapping to PubSub or `:pg`
  a one-file change if distributed events are ever needed.
  """

  @registry Minga.EventBus

  @typedoc "Known event topics."
  @type topic ::
          :buffer_saved
          | :buffer_opened
          | :mode_changed

  @typedoc "Event payload. A map with topic-specific keys."
  @type payload :: map()

  @doc """
  Returns the child spec for the event bus Registry.

  Add this to your supervision tree before any process that subscribes.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc """
  Subscribes the calling process to a topic.

  The process will be included in `Registry.dispatch/3` callbacks when
  `broadcast/2` is called for this topic. A process can subscribe to
  multiple topics. Subscribing to the same topic twice is allowed and
  results in the callback being invoked twice per broadcast.
  """
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) when is_atom(topic) do
    {:ok, _} = Registry.register(@registry, topic, [])
    :ok
  end

  @doc """
  Subscribes the calling process to a topic with metadata.

  The metadata value is passed to the dispatch callback alongside the pid,
  which lets subscribers filter or tag their registrations.
  """
  @spec subscribe(topic(), term()) :: :ok
  def subscribe(topic, value) when is_atom(topic) do
    {:ok, _} = Registry.register(@registry, topic, value)
    :ok
  end

  @doc """
  Broadcasts a payload to all subscribers of a topic.

  Each subscriber's callback receives `{pid, value}` where `value` is
  whatever was passed to `subscribe/2` (default `[]`). The callback runs
  in the caller's process, so keep it lightweight. For async work, have
  the callback send a message to the subscriber pid.

  Returns `:ok`. If no processes are subscribed to the topic, this is a
  no-op with negligible cost.
  """
  @spec broadcast(topic(), payload()) :: :ok
  def broadcast(topic, payload) when is_atom(topic) and is_map(payload) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:minga_event, topic, payload})
      end
    end)
  end

  @doc """
  Unsubscribes the calling process from a topic.

  Removes all registrations for this process under the given topic key.
  """
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_atom(topic) do
    Registry.unregister(@registry, topic)
  end

  @doc """
  Returns the list of pids subscribed to a topic.

  Useful for debugging and testing. Not intended for production dispatch
  (use `broadcast/2` instead).
  """
  @spec subscribers(topic()) :: [pid()]
  def subscribers(topic) when is_atom(topic) do
    Registry.lookup(@registry, topic) |> Enum.map(fn {pid, _} -> pid end)
  end
end
