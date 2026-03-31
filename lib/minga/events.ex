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
      Minga.Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: buf, path: path})

  Subscribers receive the event synchronously in the dispatch callback,
  which runs in the broadcaster's process. For heavy work, subscribers
  should send themselves a message and handle it asynchronously.

  ## Payload types

  Each topic has a typed struct payload with `@enforce_keys`. This means
  the compiler catches missing fields at construction time, and the type
  checker flags wrong field types (e.g. atom instead of pid). Subscribers
  pattern-match on the struct, so malformed payloads can't sneak through.

  | Topic            | Payload struct    | Required fields              |
  |------------------|-------------------|------------------------------|
  | `:buffer_saved`   | `BufferEvent`        | `buffer: pid(), path: String.t()`              |
  | `:buffer_opened`  | `BufferEvent`        | `buffer: pid(), path: String.t()`              |
  | `:buffer_closed`  | `BufferClosedEvent`  | `buffer: pid(), path: String.t() \| :scratch`  |
  | `:buffer_changed` | `BufferChangedEvent` | `buffer: pid(), source: EditSource.t()`  |
  | `:mode_changed`   | `ModeEvent`          | `old: atom(), new: atom()`        |
  | `:git_status_changed` | `GitStatusEvent` | `git_root, entries, branch, ahead, behind` |
  | `:diagnostics_updated` | `DiagnosticsUpdatedEvent` | `uri: String.t(), source: atom()` |
  | `:lsp_status_changed` | `LspStatusEvent` | `name: atom(), status: atom(), uri: String.t() \| nil` |
  | `:project_rebuilt` | `ProjectRebuiltEvent` | `root: String.t()` |
  | `:command_done`    | `CommandDoneEvent`    | `name: String.t(), exit_code: non_neg_integer()` |
  | `:log_message`     | `LogMessageEvent`     | `text: String.t(), level: :info \| :warning \| :error` |
  | `:face_overrides_changed` | `FaceOverridesChangedEvent` | `buffer: pid(), overrides: map()` |

  ## Why Registry?

  `Registry` ships with OTP (no dependencies), supports pattern-based
  dispatch, and has zero overhead for topics with no subscribers. It is
  the same primitive that Phoenix.PubSub builds on, without the Phoenix
  dependency. The wrapper module makes swapping to PubSub or `:pg`
  a one-file change if distributed events are ever needed.
  """

  @registry Minga.EventBus

  # ── Payload structs ─────────────────────────────────────────────────────────

  defmodule BufferEvent do
    @moduledoc "Payload for `:buffer_saved` and `:buffer_opened` events."
    @enforce_keys [:buffer, :path]
    defstruct [:buffer, :path]

    @type t :: %__MODULE__{buffer: pid(), path: String.t()}
  end

  defmodule BufferClosedEvent do
    @moduledoc "Payload for `:buffer_closed` events."
    @enforce_keys [:buffer, :path]
    defstruct [:buffer, :path]

    @type t :: %__MODULE__{buffer: pid(), path: String.t() | :scratch}
  end

  defmodule BufferChangedEvent do
    @moduledoc """
    Payload for `:buffer_changed` events.

    Carries the edit delta and source identity so subscribers can do
    incremental work directly from the event payload without calling
    back to the buffer.

    When `delta` is `nil`, the edit was a bulk operation (undo, redo,
    content replacement) and subscribers should fall back to full sync.
    """

    @enforce_keys [:buffer, :source]
    defstruct [:buffer, :source, :delta, :version]

    @type t :: %__MODULE__{
            buffer: pid(),
            source: Minga.Buffer.EditSource.t(),
            delta: Minga.Buffer.EditDelta.t() | nil,
            version: non_neg_integer() | nil
          }
  end

  defmodule ModeEvent do
    @moduledoc "Payload for `:mode_changed` events."
    @enforce_keys [:old, :new]
    defstruct [:old, :new]

    @type t :: %__MODULE__{old: atom(), new: atom()}
  end

  defmodule ToolMissingEvent do
    @moduledoc "Payload for `:tool_missing` events. Sent when an LSP server or formatter command is not found and a tool recipe exists."
    @enforce_keys [:command]
    defstruct [:command]

    @type t :: %__MODULE__{command: String.t()}
  end

  defmodule ProjectRebuiltEvent do
    @moduledoc "Payload for `:project_rebuilt` events. Published when the file cache rebuild completes."
    @enforce_keys [:root]
    defstruct [:root]

    @type t :: %__MODULE__{root: String.t()}
  end

  defmodule CommandDoneEvent do
    @moduledoc "Payload for `:command_done` events. Published when a CommandOutput process finishes."
    @enforce_keys [:name, :exit_code]
    defstruct [:name, :exit_code]

    @type t :: %__MODULE__{name: String.t(), exit_code: non_neg_integer()}
  end

  defmodule GitStatusEvent do
    @moduledoc "Payload for `:git_status_changed` events. Published by `Git.Repo` when repo status changes."
    @enforce_keys [:git_root, :entries, :branch, :ahead, :behind]
    defstruct [:git_root, :entries, :branch, :ahead, :behind]

    @type t :: %__MODULE__{
            git_root: String.t(),
            entries: [Minga.Git.StatusEntry.t()],
            branch: String.t() | nil,
            ahead: non_neg_integer(),
            behind: non_neg_integer()
          }
  end

  defmodule DiagnosticsUpdatedEvent do
    @moduledoc "Payload for `:diagnostics_updated` events. Published by `Diagnostics` when diagnostics are published or cleared for a URI."
    @enforce_keys [:uri, :source]
    defstruct [:uri, :source]

    @type t :: %__MODULE__{uri: String.t(), source: atom()}
  end

  defmodule LspStatusEvent do
    @moduledoc "Payload for `:lsp_status_changed` events. Published by `LSP.Client` on status transitions."
    @enforce_keys [:name, :status]
    defstruct [:name, :status, :uri]

    @type t :: %__MODULE__{
            name: atom(),
            status: :starting | :initializing | :ready | :stopped | :crashed,
            uri: String.t() | nil
          }
  end

  defmodule LogMessageEvent do
    @moduledoc """
    Payload for `:log_message` events.

    Sent by Layer 0/1 modules (LSP, Git, Agent) when they want to log to
    `*Messages*` without importing `MingaEditor`. The Editor subscribes
    to this topic and routes the message through `MessageLog`.
    """
    @enforce_keys [:text, :level]
    defstruct [:text, :level]

    @type level :: :info | :warning | :error
    @type t :: %__MODULE__{text: String.t(), level: level()}
  end

  defmodule FaceOverridesChangedEvent do
    @moduledoc """
    Payload for `:face_overrides_changed` events.

    Sent by `Buffer.Server` when buffer-local face overrides change so
    the Editor can pre-compute the merged face registry without a
    GenServer call back into the buffer.
    """
    @enforce_keys [:buffer, :overrides]
    defstruct [:buffer, :overrides]

    @type t :: %__MODULE__{buffer: pid(), overrides: %{String.t() => keyword()}}
  end

  defmodule SupervisorRestartedEvent do
    @moduledoc "Payload for `:supervisor_restarted` events. Published by `SystemObserver` when a monitored supervisor goes down."
    @enforce_keys [:name, :pid, :reason, :restarted_at]
    defstruct [:name, :pid, :reason, :restarted_at]

    @type t :: %__MODULE__{
            name: atom(),
            pid: pid(),
            reason: term(),
            restarted_at: DateTime.t()
          }
  end

  # ── Types ───────────────────────────────────────────────────────────────────

  @typedoc "Known event topics."
  @type topic ::
          :buffer_saved
          | :buffer_opened
          | :buffer_closed
          | :buffer_changed
          | :content_replaced
          | :mode_changed
          | :git_status_changed
          | :diagnostics_updated
          | :lsp_status_changed
          | :tool_install_started
          | :tool_install_progress
          | :tool_install_complete
          | :tool_install_failed
          | :tool_uninstall_complete
          | :tool_missing
          | :project_rebuilt
          | :command_done
          | :supervisor_restarted
          | :log_message
          | :face_overrides_changed

  @typedoc "Typed event payloads. Each topic has a specific struct."
  @type payload ::
          BufferEvent.t()
          | BufferClosedEvent.t()
          | BufferChangedEvent.t()
          | ModeEvent.t()
          | ToolMissingEvent.t()
          | ProjectRebuiltEvent.t()
          | CommandDoneEvent.t()
          | GitStatusEvent.t()
          | DiagnosticsUpdatedEvent.t()
          | LspStatusEvent.t()
          | SupervisorRestartedEvent.t()
          | LogMessageEvent.t()
          | FaceOverridesChangedEvent.t()

  # ── Child spec ──────────────────────────────────────────────────────────────

  @doc """
  Returns the child spec for the event bus Registry.

  Add this to your supervision tree before any process that subscribes.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  # ── Subscribe / Unsubscribe ─────────────────────────────────────────────────

  @doc """
  Subscribes the calling process to a topic.

  The process will be included in `Registry.dispatch/3` callbacks when
  `broadcast/2` is called for this topic. A process can subscribe to
  multiple topics. Subscribing to the same topic multiple times from
  the same process is a no-op.
  """
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) when is_atom(topic) do
    if Process.whereis(@registry) do
      already? =
        Registry.lookup(@registry, topic)
        |> Enum.any?(fn {pid, _} -> pid == self() end)

      unless already?, do: {:ok, _} = Registry.register(@registry, topic, [])
    end

    :ok
  end

  @doc """
  Subscribes the calling process to a topic with metadata.

  The metadata value is passed to the dispatch callback alongside the pid,
  which lets subscribers filter or tag their registrations. Subscribing
  with the same topic and value from the same process is a no-op.
  """
  @spec subscribe(topic(), term()) :: :ok
  def subscribe(topic, value) when is_atom(topic) do
    if Process.whereis(@registry) do
      already? =
        Registry.lookup(@registry, topic)
        |> Enum.any?(fn {pid, v} -> pid == self() and v == value end)

      unless already?, do: {:ok, _} = Registry.register(@registry, topic, value)
    end

    :ok
  end

  @doc """
  Unsubscribes the calling process from a topic.

  Removes all registrations for this process under the given topic key.
  """
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_atom(topic) do
    Registry.unregister(@registry, topic)
  end

  # ── Broadcast ───────────────────────────────────────────────────────────────

  @doc """
  Broadcasts a typed payload to all subscribers of a topic.

  Accepts `BufferEvent` for buffer topics and `ModeEvent` for mode changes.
  Using structs with `@enforce_keys` means the compiler catches missing
  fields and the type checker flags wrong field types at the call site,
  before the event ever reaches subscribers.

  Returns `:ok`. If no processes are subscribed to the topic, this is a
  no-op with negligible cost.
  """
  @spec broadcast(:buffer_saved | :buffer_opened | :content_replaced, BufferEvent.t()) :: :ok
  @spec broadcast(:buffer_closed, BufferClosedEvent.t()) :: :ok
  @spec broadcast(:buffer_changed, BufferChangedEvent.t()) :: :ok
  @spec broadcast(:mode_changed, ModeEvent.t()) :: :ok
  @spec broadcast(:tool_missing, ToolMissingEvent.t()) :: :ok
  @spec broadcast(:project_rebuilt, ProjectRebuiltEvent.t()) :: :ok
  @spec broadcast(:command_done, CommandDoneEvent.t()) :: :ok
  @spec broadcast(:git_status_changed, GitStatusEvent.t()) :: :ok
  @spec broadcast(:diagnostics_updated, DiagnosticsUpdatedEvent.t()) :: :ok
  @spec broadcast(:lsp_status_changed, LspStatusEvent.t()) :: :ok
  @spec broadcast(:supervisor_restarted, SupervisorRestartedEvent.t()) :: :ok
  @spec broadcast(:log_message, LogMessageEvent.t()) :: :ok
  @spec broadcast(:face_overrides_changed, FaceOverridesChangedEvent.t()) :: :ok
  def broadcast(topic, %_{} = payload) when is_atom(topic) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:minga_event, topic, payload})
      end
    end)
  end

  @doc """
  Broadcasts `:buffer_changed` to all subscribers.

  Deprecated: use the 2-arity version that accepts a `BufferChangedEvent`
  struct with delta and source fields. This 1-arity wrapper exists for
  backward compatibility during migration.
  """
  @deprecated "Buffer.Server now broadcasts :buffer_changed automatically on every edit. No manual broadcast needed."
  @spec notify_buffer_changed(pid()) :: :ok
  def notify_buffer_changed(buf) when is_pid(buf) do
    broadcast(:buffer_changed, %BufferChangedEvent{
      buffer: buf,
      source: Minga.Buffer.EditSource.unknown()
    })
  end

  # ── Query ───────────────────────────────────────────────────────────────────

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
