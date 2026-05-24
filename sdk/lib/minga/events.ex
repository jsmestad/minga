defmodule Minga.Events do
  @moduledoc """
  Event bus for subscribing to editor lifecycle events.

  Extensions use `subscribe/1` to receive events in their process mailbox
  as `{:minga_event, topic, payload}` messages.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @type topic ::
          :buffer_saved
          | :buffer_opened
          | :buffer_closed
          | :buffer_changed
          | :mode_changed
          | :git_status_changed
          | :diagnostics_updated
          | :agent_session_stopped
          | :agent_hook
          | :file_written
          | :ghost_cursor_removed

  @spec subscribe(topic()) :: :ok
  def subscribe(_topic), do: raise("minga_sdk is compile-time only")

  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(_topic), do: raise("minga_sdk is compile-time only")

  @spec broadcast(atom(), map()) :: :ok
  def broadcast(_topic, _payload), do: raise("minga_sdk is compile-time only")

  defmodule BufferChangedEvent do
    @moduledoc "Payload for `:buffer_changed` events."
    @enforce_keys [:buffer, :source]
    defstruct [:buffer, :source, :delta, :version]

    @type t :: %__MODULE__{
            buffer: pid(),
            source: term(),
            delta: term(),
            version: non_neg_integer() | nil
          }
  end

  defmodule BufferEvent do
    @moduledoc "Payload for `:buffer_saved` and `:buffer_opened` events."
    @enforce_keys [:buffer, :path]
    defstruct [:buffer, :path]

    @type t :: %__MODULE__{buffer: pid(), path: String.t()}
  end
end
