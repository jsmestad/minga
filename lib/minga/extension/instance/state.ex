defmodule Minga.Extension.Instance.State do
  @moduledoc "Pure lifecycle state and phase transitions for one extension Instance."

  alias Minga.Extension.Entry
  alias Minga.Extension.Instance.Artifact
  alias Minga.Extension.Instance.CleanupFailure
  alias Minga.Extension.Instance.PhaseFailure
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.StartContext
  alias Minga.Extension.Instance.StopContext

  @type queued_start :: {:current, GenServer.from()} | {:deferred, GenServer.from(), Entry.t()}
  @type phase ::
          :stopped
          | {:stub, Artifact.t()}
          | {:starting, StartContext.t()}
          | {:running, Runtime.t()}
          | {:stopping, StopContext.t()}
          | {:crashed, PhaseFailure.t()}
          | {:load_error, PhaseFailure.t()}
          | {:cleanup_failed, CleanupFailure.t()}

  @enforce_keys [:name, :declaration, :registry, :instance_registry, :collaborators]
  defstruct [
    :name,
    :declaration,
    :registry,
    :instance_registry,
    :collaborators,
    artifact: :unprepared,
    restart_count: 0,
    phase: :stopped
  ]

  @type t :: %__MODULE__{
          name: atom(),
          declaration: Entry.t(),
          registry: GenServer.server(),
          instance_registry: atom(),
          collaborators: keyword(),
          artifact: :unprepared | {:prepared, Artifact.t()},
          restart_count: non_neg_integer(),
          phase: phase()
        }

  @doc "Constructs a stopped lifecycle state from its declaration."
  @spec new(atom(), Entry.t(), GenServer.server(), atom(), keyword()) :: t()
  def new(name, declaration, registry, instance_registry, collaborators) do
    %__MODULE__{
      name: name,
      declaration: declaration_only(declaration),
      registry: registry,
      instance_registry: instance_registry,
      collaborators: stable_collaborators(collaborators)
    }
  end

  @doc "Updates declaration identity and collaborators while no transition is active."
  @spec declare(t(), Entry.t(), GenServer.server(), keyword()) :: {:ok, t()} | {:error, term()}
  def declare(%__MODULE__{phase: phase} = state, declaration, registry, collaborators)
      when phase == :stopped or
             (is_tuple(phase) and elem(phase, 0) in [:load_error, :crashed]) do
    {:ok,
     %{
       state
       | declaration: declaration_only(declaration),
         registry: registry,
         collaborators: current_collaborators(state.collaborators, collaborators),
         artifact: declaration_artifact(state.declaration, declaration, state.artifact)
     }}
  end

  def declare(%__MODULE__{declaration: current} = state, declaration, registry, collaborators) do
    if declaration_only(current) == declaration_only(declaration) do
      {:ok,
       %{
         state
         | registry: registry,
           collaborators: current_collaborators(state.collaborators, collaborators)
       }}
    else
      {:error, {:declaration_busy, state.name}}
    end
  end

  @doc "Replaces per-request lifecycle collaborators while retaining stable injections."
  @spec configure(t(), keyword()) :: t()
  def configure(state, collaborators) do
    %{state | collaborators: current_collaborators(state.collaborators, collaborators)}
  end

  @doc "Removes request-scoped callbacks, hooks, and timeout overrides."
  @spec stable_collaborators(keyword()) :: keyword()
  def stable_collaborators(collaborators) do
    Enum.reject(collaborators, fn {key, _value} -> request_override?(key) end)
  end

  @doc "Stores the immutable current-generation artifact."
  @spec put_artifact(t(), Artifact.t()) :: t()
  def put_artifact(state, artifact), do: %{state | artifact: {:prepared, artifact}}

  @doc "Returns the prepared artifact when available."
  @spec artifact(t()) :: {:ok, Artifact.t()} | :error
  def artifact(%__MODULE__{artifact: {:prepared, artifact}}), do: {:ok, artifact}
  def artifact(%__MODULE__{}), do: :error

  @doc "Moves the authority into a start transition."
  @spec starting(t(), StartContext.t()) :: t()
  def starting(state, context), do: %{state | phase: {:starting, context}}

  @doc "Moves the authority into the running phase."
  @spec running(t(), Runtime.t()) :: t()
  def running(state, runtime), do: %{state | phase: {:running, runtime}}

  @doc "Moves the authority into a stop transition with an existing context."
  @spec stopping(t(), StopContext.t()) :: t()
  def stopping(state, context), do: %{state | phase: {:stopping, context}}

  @doc "Builds the initial asynchronous stop context."
  @spec stopping(t(), GenServer.from() | nil, :explicit | :normal | :crash, term()) :: t()
  def stopping(state, waiter, exit_kind, exit_reason) do
    context = StopContext.new(waiter, exit_kind, exit_reason, runtime(state.phase))
    stopping(state, context)
  end

  @doc "Moves the authority to the lazy stub phase."
  @spec stubbed(t(), Artifact.t()) :: t()
  def stubbed(state, artifact), do: %{state | phase: {:stub, artifact}}

  @doc "Moves the authority to a terminal stopped phase."
  @spec stopped(t()) :: t()
  def stopped(state), do: %{state | phase: :stopped}

  @doc "Applies the terminal phase implied by a completed stop context."
  @spec terminal(t(), StopContext.t()) :: t()
  def terminal(state, %StopContext{exit_kind: :crash, exit_reason: reason}),
    do: crashed(state, reason)

  def terminal(state, %StopContext{}), do: stopped(state)

  @doc "Moves the authority to a terminal crash phase."
  @spec crashed(t(), term()) :: t()
  def crashed(state, reason), do: %{state | phase: {:crashed, PhaseFailure.new(reason)}}

  @doc "Moves the authority to a terminal load-error phase."
  @spec load_error(t(), term()) :: t()
  def load_error(state, reason), do: %{state | phase: {:load_error, PhaseFailure.new(reason)}}

  @doc "Moves the authority to cleanup-failed with a resumable stop context."
  @spec cleanup_failed(t(), term(), StopContext.t()) :: t()
  def cleanup_failed(state, reason, retry) do
    %{state | phase: {:cleanup_failed, CleanupFailure.new(reason, retry)}}
  end

  @doc "Replaces the reason of the current terminal failure phase."
  @spec replace_terminal_failure(t(), term()) :: t()
  def replace_terminal_failure(%__MODULE__{phase: {:cleanup_failed, failure}} = state, reason) do
    %{state | phase: {:cleanup_failed, CleanupFailure.replace_reason(failure, reason)}}
  end

  def replace_terminal_failure(state, reason), do: load_error(state, reason)

  @doc "Increments the authority-owned crash restart count."
  @spec increment_restart(t()) :: t()
  def increment_restart(state), do: %{state | restart_count: state.restart_count + 1}

  @doc "Adds a caller to a transition's stop waiter list."
  @spec join_stop(t(), GenServer.from()) :: t()
  def join_stop(%__MODULE__{phase: {:stopping, context}} = state, from) do
    stopping(state, StopContext.join(context, from))
  end

  @doc "Queues a start intent behind a safe stop."
  @spec queue_start(t(), queued_start()) :: t()
  def queue_start(%__MODULE__{phase: {:stopping, context}} = state, queued_start) do
    stopping(state, StopContext.queue_start(context, queued_start))
  end

  @doc "Returns runtime identity only from phases that own it."
  @spec runtime(phase()) :: Runtime.t() | nil
  def runtime({:running, runtime}), do: runtime
  def runtime({:stopping, %StopContext{runtime: runtime}}), do: runtime
  def runtime(_phase), do: nil

  @doc "Removes projection fields from a registry snapshot."
  @spec declaration_only(Entry.t()) :: Entry.t()
  def declaration_only(%Entry{} = entry) do
    declared_module = if entry.source_type == :module, do: entry.module, else: nil

    %{
      entry
      | module: declared_module,
        pid: nil,
        manifest: nil,
        last_error: nil,
        status: :stopped
    }
  end

  @spec current_collaborators(keyword(), keyword()) :: keyword()
  defp current_collaborators(previous, current) do
    previous
    |> stable_collaborators()
    |> Keyword.merge(current)
  end

  @spec request_override?(atom()) :: boolean()
  defp request_override?(:callbacks), do: true
  defp request_override?(:test_hooks), do: true
  defp request_override?(:slow_lifecycle_threshold_ms), do: true

  defp request_override?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.ends_with?("_timeout_ms")
  end

  @spec declaration_artifact(
          Entry.t(),
          Entry.t(),
          :unprepared | {:prepared, Artifact.t()}
        ) :: :unprepared | {:prepared, Artifact.t()}
  defp declaration_artifact(old, new, artifact) do
    if declaration_only(old) == declaration_only(new), do: artifact, else: :unprepared
  end
end
