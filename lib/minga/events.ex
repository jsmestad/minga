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
  | `:git_status_changed` | `GitStatusEvent` | `git_root, entries, branch, ahead, behind` plus cached `last_commit_message` |
  | `:diagnostics_updated` | `DiagnosticsUpdatedEvent` | `uri: String.t(), source: atom()` |
  | `:lsp_status_changed` | `LspStatusEvent` | `name: atom(), status: atom(), uri: String.t() \| nil` |
  | `:project_rebuilt` | `ProjectRebuiltEvent` | `root: String.t()` |
  | `:command_done`    | `CommandDoneEvent`    | `name: String.t(), exit_code: non_neg_integer()` |
  | `:log_message`     | `LogMessageEvent`     | `text: String.t(), level: :info \| :warning \| :error` |
  | `:agent_hook`      | `AgentHookEvent`        | `event, phase, tool_name, tool_call_id, tool_pattern` |
  | `:face_overrides_changed` | `FaceOverridesChangedEvent` | `buffer: pid(), overrides: map()` |
  | `:background_subagent_started` | `MingaAgent.Subagent.Handle` | `session_id: String.t(), pid: pid(), task: String.t()` |
  | `:node_connected` | `Minga.Distribution.Events.NodeConnectedEvent` | `server_name, node, connected_at` |
  | `:node_disconnected` | `Minga.Distribution.Events.NodeDisconnectedEvent` | `server_name, node, reason, disconnected_at` |
  | `:power_thermal_state_changed` | `PowerThermalStateEvent` | `low_power?, thermal_state` |

  ## Why Registry?

  `Registry` ships with OTP (no dependencies), supports pattern-based
  dispatch, and has zero overhead for topics with no subscribers. It is
  the same primitive that Phoenix.PubSub builds on, without the Phoenix
  dependency. The wrapper module makes swapping to PubSub or `:pg`
  a one-file change if distributed events are ever needed.
  """

  @default_registry Minga.EventBus

  @typedoc "Registry process name used by the event bus."
  @type registry :: atom()

  @doc "Returns the production event bus registry name."
  @spec default_registry() :: registry()
  def default_registry, do: @default_registry

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

  defmodule FileWrittenEvent do
    @moduledoc "Payload for `:file_written` events. Published when a file is written to disk by an agent tool, FileWatcher, or external process."
    @enforce_keys [:path, :change_type]
    defstruct [:path, :change_type]

    @type change_type :: :created | :changed | :deleted
    @type t :: %__MODULE__{path: String.t(), change_type: change_type()}
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
    defstruct [
      :git_root,
      :entries,
      :branch,
      :ahead,
      :behind,
      last_commit_message: "",
      stash_count: 0
    ]

    @type t :: %__MODULE__{
            git_root: String.t(),
            entries: [Minga.Git.StatusEntry.t()],
            branch: String.t() | nil,
            ahead: non_neg_integer(),
            behind: non_neg_integer(),
            last_commit_message: String.t(),
            stash_count: non_neg_integer()
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

  defmodule AgentHookEvent do
    @moduledoc "Payload for `:agent_hook` lifecycle telemetry events."
    @enforce_keys [:event, :phase]
    defstruct [:event, :phase, :tool_name, :tool_call_id, :tool_pattern, :exit_status, :reason]

    @type phase :: :started | :allowed | :vetoed
    @type t :: %__MODULE__{
            event: String.t(),
            phase: phase(),
            tool_name: String.t() | nil,
            tool_call_id: String.t() | nil,
            tool_pattern: String.t() | nil,
            exit_status: non_neg_integer() | nil,
            reason: term()
          }
  end

  defmodule FaceOverridesChangedEvent do
    @moduledoc """
    Payload for `:face_overrides_changed` events.

    Sent by `Buffer.Process` when buffer-local face overrides change so
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

  defmodule LoadUserThemesEvent do
    @moduledoc "Payload for `:load_user_themes` events. Signals that Config.Loader wants themes loaded."
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule OptionChangedEvent do
    @moduledoc "Payload for `:option_changed` events. Published when a global config option changes at runtime."
    @enforce_keys [:source, :name, :value]
    defstruct [:source, :name, :value]

    @type t :: %__MODULE__{source: GenServer.server(), name: atom(), value: term()}
  end

  defmodule PowerThermalStateEvent do
    @moduledoc "Payload for `:power_thermal_state_changed` events. Published by the native GUI when macOS low power mode or thermal pressure changes."
    @enforce_keys [:low_power?, :thermal_state]
    defstruct [:low_power?, :thermal_state]

    @type thermal_state :: :nominal | :fair | :serious | :critical | {:unknown, non_neg_integer()}
    @type t :: %__MODULE__{low_power?: boolean(), thermal_state: thermal_state()}
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
          | :agent_session_stopped
          | :agent_hook
          | :background_subagent_started
          | :node_connected
          | :node_disconnected
          | :changeset_merged
          | :changeset_budget_exhausted
          | :load_user_themes
          | :option_changed
          | :power_thermal_state_changed
          | :buffer_fork_conflict
          | :file_written
          | :extension_updates_available
          | :ghost_cursor_removed

  @typedoc "Typed event payloads. Each topic has a specific struct."
  @type payload ::
          BufferEvent.t()
          | BufferClosedEvent.t()
          | FileWrittenEvent.t()
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
          | AgentHookEvent.t()
          | FaceOverridesChangedEvent.t()
          | LoadUserThemesEvent.t()
          | OptionChangedEvent.t()
          | PowerThermalStateEvent.t()
          | MingaAgent.SessionManager.SessionStoppedEvent.t()
          | MingaAgent.Subagent.Handle.t()
          | Minga.Distribution.Events.NodeConnectedEvent.t()
          | Minga.Distribution.Events.NodeDisconnectedEvent.t()
          | MingaAgent.Changeset.MergedEvent.t()
          | MingaAgent.Changeset.BudgetExhaustedEvent.t()
          | Minga.Extension.UpdatesAvailableEvent.t()
          | map()

  # ── Child spec ──────────────────────────────────────────────────────────────

  @doc """
  Returns the child spec for the event bus Registry.

  Add this to your supervision tree before any process that subscribes.
  Pass `name:` to start an isolated registry for tests.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Registry.child_spec(keys: :duplicate, name: Keyword.get(opts, :name, default_registry()))
  end

  # ── Subscribe / Unsubscribe ─────────────────────────────────────────────────

  @doc """
  Subscribes the calling process to a topic on the default registry.

  The process will be included in `Registry.dispatch/3` callbacks when
  `broadcast/2` is called for this topic. A process can subscribe to
  multiple topics. Subscribing to the same topic multiple times from
  the same process is a no-op.
  """
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) when is_atom(topic) do
    subscribe_topic(topic, [], default_registry())
  end

  @doc """
  Subscribes the calling process to a topic with metadata or a registry.

  Pass `registry: name` to subscribe without metadata on an isolated registry.
  Passing a running Registry name directly is also supported for the migration.
  Otherwise the second argument is preserved as metadata on the default registry.
  """
  @spec subscribe(topic(), keyword() | registry() | term()) :: :ok
  def subscribe(topic, opts) when is_atom(topic) and is_list(opts) do
    if registry_opts?(opts) do
      subscribe_topic(topic, [], Keyword.fetch!(opts, :registry))
    else
      subscribe_topic(topic, opts, default_registry())
    end
  end

  def subscribe(topic, registry_or_value) when is_atom(topic) do
    if registry_process?(registry_or_value) do
      subscribe_topic(topic, [], registry_or_value)
    else
      subscribe_topic(topic, registry_or_value, default_registry())
    end
  end

  @doc """
  Subscribes the calling process to a topic with metadata on a registry.

  The metadata value is passed to the dispatch callback alongside the pid,
  which lets subscribers filter or tag their registrations. Subscribing
  with the same topic and value from the same process is a no-op.
  """
  @spec subscribe(topic(), term(), keyword()) :: :ok
  @spec subscribe(topic(), term(), registry()) :: :ok
  def subscribe(topic, value, opts) when is_atom(topic) and is_list(opts) do
    subscribe_topic(topic, value, Keyword.get(opts, :registry, default_registry()))
  end

  def subscribe(topic, value, registry) when is_atom(topic) do
    subscribe_topic(topic, value, registry)
  end

  @doc """
  Unsubscribes the calling process from a topic.

  Removes all registrations for this process under the given topic key.
  """
  @spec unsubscribe(topic()) :: :ok
  @spec unsubscribe(topic(), keyword() | registry()) :: :ok
  def unsubscribe(topic, registry_or_opts \\ default_registry()) when is_atom(topic) do
    registry = registry_from_arg(registry_or_opts)

    if registry_process?(registry) do
      Registry.unregister(registry, topic)
    end

    :ok
  end

  # ── Broadcast ───────────────────────────────────────────────────────────────

  @doc """
  Broadcasts a typed payload to all subscribers of a topic.

  Accepts typed payload structs for known topics. Returns `:ok`. If no
  processes are subscribed to the topic, this is a no-op with negligible cost.
  Pass `registry:` or a registry name as the third argument to broadcast through
  an isolated registry.
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
  @spec broadcast(:option_changed, OptionChangedEvent.t()) :: :ok
  @spec broadcast(:power_thermal_state_changed, PowerThermalStateEvent.t()) :: :ok
  @spec broadcast(:face_overrides_changed, FaceOverridesChangedEvent.t()) :: :ok
  @spec broadcast(:agent_session_stopped, MingaAgent.SessionManager.SessionStoppedEvent.t()) ::
          :ok
  @spec broadcast(:background_subagent_started, MingaAgent.Subagent.Handle.t()) :: :ok
  @spec broadcast(:node_connected, Minga.Distribution.Events.NodeConnectedEvent.t()) :: :ok
  @spec broadcast(:node_disconnected, Minga.Distribution.Events.NodeDisconnectedEvent.t()) :: :ok
  @spec broadcast(:changeset_merged, MingaAgent.Changeset.MergedEvent.t()) :: :ok
  @spec broadcast(:changeset_budget_exhausted, MingaAgent.Changeset.BudgetExhaustedEvent.t()) ::
          :ok
  @spec broadcast(:load_user_themes, LoadUserThemesEvent.t()) :: :ok
  @spec broadcast(:agent_hook, AgentHookEvent.t()) :: :ok
  @spec broadcast(:buffer_fork_conflict, map()) :: :ok
  @spec broadcast(:file_written, FileWrittenEvent.t()) :: :ok
  @spec broadcast(:extension_updates_available, Minga.Extension.UpdatesAvailableEvent.t()) :: :ok
  def broadcast(topic, payload) when is_atom(topic) and is_map(payload) do
    broadcast(topic, payload, default_registry())
  end

  @spec broadcast(topic(), payload(), keyword()) :: :ok
  @spec broadcast(topic(), payload(), registry()) :: :ok
  def broadcast(topic, payload, registry_or_opts) when is_atom(topic) and is_map(payload) do
    registry = registry_from_arg(registry_or_opts)
    if registry_process?(registry), do: dispatch(registry, topic, payload)
    :ok
  end

  @doc """
  Broadcasts `:buffer_changed` to all subscribers.

  Deprecated: use the 2-arity version that accepts a `BufferChangedEvent`
  struct with delta and source fields. This wrapper exists for backward
  compatibility during migration.
  """
  @deprecated "Buffer.Process now broadcasts :buffer_changed automatically on every edit. No manual broadcast needed."
  @spec notify_buffer_changed(pid()) :: :ok
  @spec notify_buffer_changed(pid(), keyword() | registry()) :: :ok
  def notify_buffer_changed(buf, registry_or_opts \\ default_registry()) when is_pid(buf) do
    broadcast(
      :buffer_changed,
      %BufferChangedEvent{
        buffer: buf,
        source: Minga.Buffer.EditSource.unknown()
      },
      registry_or_opts
    )
  end

  # ── Query ───────────────────────────────────────────────────────────────────

  @doc """
  Returns the list of pids subscribed to a topic.

  Useful for debugging and testing. Not intended for production dispatch
  (use `broadcast/2` instead).
  """
  @spec subscribers(topic()) :: [pid()]
  @spec subscribers(topic(), keyword() | registry()) :: [pid()]
  def subscribers(topic, registry_or_opts \\ default_registry()) when is_atom(topic) do
    registry = registry_from_arg(registry_or_opts)

    if registry_process?(registry) do
      Registry.lookup(registry, topic) |> Enum.map(fn {pid, _} -> pid end)
    else
      []
    end
  end

  @spec dispatch(registry(), topic(), payload()) :: :ok
  defp dispatch(registry, topic, payload) do
    Registry.dispatch(registry, topic, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:minga_event, topic, payload})
      end
    end)
  end

  @spec subscribe_topic(topic(), term(), registry()) :: :ok
  defp subscribe_topic(topic, value, registry) do
    if registry_process?(registry) do
      already? =
        Registry.lookup(registry, topic)
        |> Enum.any?(fn {pid, v} -> pid == self() and v == value end)

      unless already?, do: {:ok, _} = Registry.register(registry, topic, value)
    end

    :ok
  end

  @spec registry_from_arg(keyword() | registry()) :: registry()
  defp registry_from_arg(opts) when is_list(opts),
    do: Keyword.get(opts, :registry, default_registry())

  defp registry_from_arg(registry) when is_atom(registry), do: registry

  @spec registry_opts?(list()) :: boolean()
  defp registry_opts?(opts) do
    Keyword.keyword?(opts) and Keyword.has_key?(opts, :registry)
  end

  @spec registry_process?(term()) :: boolean()
  defp registry_process?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp registry_process?(_), do: false
end
