defmodule Minga.Parser.BufferRegistry do
  @moduledoc """
  Pure ownership for editor-buffer identity and lifecycle inside the parser process.

  The parser manager process owns one registry value. This module keeps parser IDs, crash-resync metadata, parse sequencing, activity timestamps, and eviction decisions coherent without spreading raw map updates through GenServer callbacks.
  """

  alias Minga.Parser.BufferRegistration

  @typedoc "Tracked buffer metadata used to rebuild parser state after a restart."
  @type meta :: BufferRegistration.t()

  @type t :: %__MODULE__{
          entries: %{pid() => meta()},
          ids: %{pid() => pos_integer()},
          pids: %{pos_integer() => pid()},
          next_id: pos_integer(),
          parse_version: non_neg_integer(),
          last_active_at: %{pid() => integer()},
          monitors: %{pid() => reference()}
        }

  defstruct entries: %{},
            ids: %{},
            pids: %{},
            next_id: 1,
            parse_version: 0,
            last_active_at: %{},
            monitors: %{}

  @doc "Creates an empty editor-buffer registry."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Registers or refreshes a buffer and returns its stable ID and whether it was newly tracked."
  @spec register(
          t(),
          pid(),
          String.t(),
          (-> String.t()),
          (non_neg_integer() -> [binary()]) | nil,
          integer()
        ) ::
          {pos_integer(), :new | :existing, t()}
  def register(%__MODULE__{} = registry, buffer_pid, language, content_fn, setup_fn, now)
      when is_pid(buffer_pid) and is_binary(language) and is_function(content_fn, 0) do
    {buffer_id, status, next_id} = registration_identity(registry, buffer_pid)

    meta = %BufferRegistration{
      id: buffer_id,
      language: language,
      content_fn: content_fn,
      setup_commands_fn: setup_fn
    }

    registry = %{
      registry
      | entries: Map.put(registry.entries, buffer_pid, meta),
        ids: Map.put(registry.ids, buffer_pid, buffer_id),
        pids: Map.put(registry.pids, buffer_id, buffer_pid),
        next_id: next_id,
        last_active_at: Map.put(registry.last_active_at, buffer_pid, now)
    }

    {buffer_id, status, registry}
  end

  @doc "Records the process monitor owned by the parser manager for a registered buffer."
  @spec put_monitor(t(), pid(), reference()) :: t()
  def put_monitor(%__MODULE__{} = registry, buffer_pid, monitor_ref)
      when is_pid(buffer_pid) and is_reference(monitor_ref) do
    %{registry | monitors: Map.put(registry.monitors, buffer_pid, monitor_ref)}
  end

  @doc "Returns whether a DOWN message belongs to the current monitor for a buffer."
  @spec monitored?(t(), pid(), reference()) :: boolean()
  def monitored?(%__MODULE__{monitors: monitors}, buffer_pid, monitor_ref) do
    Map.get(monitors, buffer_pid) == monitor_ref
  end

  @doc "Returns the parser ID for a buffer PID."
  @spec buffer_id(t(), pid()) :: pos_integer() | nil
  def buffer_id(%__MODULE__{ids: ids}, buffer_pid), do: Map.get(ids, buffer_pid)

  @doc "Returns the buffer PID for a parser ID."
  @spec resolve(t(), non_neg_integer()) :: pid() | nil
  def resolve(%__MODULE__{pids: pids}, buffer_id), do: Map.get(pids, buffer_id)

  @doc "Returns whether a parser ID belongs to an editor buffer."
  @spec registered_id?(t(), non_neg_integer()) :: boolean()
  def registered_id?(%__MODULE__{pids: pids}, buffer_id), do: Map.has_key?(pids, buffer_id)

  @doc "Allocates the next parse version and refreshes activity for a registered buffer."
  @spec begin_parse(t(), pid(), integer()) :: {:ok, pos_integer(), pos_integer(), t()} | :error
  def begin_parse(%__MODULE__{} = registry, buffer_pid, now) do
    case Map.fetch(registry.ids, buffer_pid) do
      {:ok, buffer_id} ->
        version = registry.parse_version + 1

        registry = %{
          registry
          | parse_version: version,
            last_active_at: Map.put(registry.last_active_at, buffer_pid, now)
        }

        {:ok, buffer_id, version, registry}

      :error ->
        :error
    end
  end

  @doc "Refreshes activity for a registered buffer."
  @spec touch(t(), pid(), integer()) :: t()
  def touch(%__MODULE__{} = registry, buffer_pid, now) do
    if Map.has_key?(registry.ids, buffer_pid) do
      %{registry | last_active_at: Map.put(registry.last_active_at, buffer_pid, now)}
    else
      registry
    end
  end

  @doc "Unregisters a buffer and returns its former parser ID and monitor reference."
  @spec unregister(t(), pid()) :: {pos_integer() | nil, reference() | nil, t()}
  def unregister(%__MODULE__{} = registry, buffer_pid) do
    {buffer_id, ids} = Map.pop(registry.ids, buffer_pid)
    {monitor_ref, monitors} = Map.pop(registry.monitors, buffer_pid)

    registry = %{
      registry
      | entries: Map.delete(registry.entries, buffer_pid),
        ids: ids,
        pids: delete_reverse_id(registry.pids, buffer_id),
        last_active_at: Map.delete(registry.last_active_at, buffer_pid),
        monitors: monitors
    }

    {buffer_id, monitor_ref, registry}
  end

  @doc "Evicts stale unprotected buffers and returns their PIDs and parser IDs."
  @spec evict_inactive(t(), [pid()], non_neg_integer(), integer()) ::
          {[{pid(), pos_integer(), reference() | nil}], t()}
  def evict_inactive(%__MODULE__{} = registry, protected_pids, ttl_ms, now) do
    protected = MapSet.new(protected_pids)

    stale_pids =
      registry.last_active_at
      |> Enum.filter(fn {buffer_pid, last_active_at} ->
        now - last_active_at > ttl_ms and not MapSet.member?(protected, buffer_pid)
      end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(stale_pids, {[], registry}, fn buffer_pid, {evicted, acc} ->
      {buffer_id, monitor_ref, acc} = unregister(acc, buffer_pid)
      {[{buffer_pid, buffer_id, monitor_ref} | evicted], acc}
    end)
    |> then(fn {evicted, updated} -> {Enum.reverse(evicted), updated} end)
  end

  @doc "Returns all crash-resync entries."
  @spec entries(t()) :: %{pid() => meta()}
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc "Returns the number of tracked editor buffers."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{entries: entries}), do: map_size(entries)

  @doc "Resets outgoing parse sequencing after parser restart."
  @spec reset_parse_version(t()) :: t()
  def reset_parse_version(%__MODULE__{} = registry), do: %{registry | parse_version: 0}

  @spec delete_reverse_id(%{pos_integer() => pid()}, pos_integer() | nil) :: %{
          pos_integer() => pid()
        }
  defp delete_reverse_id(pids, nil), do: pids
  defp delete_reverse_id(pids, buffer_id), do: Map.delete(pids, buffer_id)

  @spec registration_identity(t(), pid()) :: {pos_integer(), :new | :existing, pos_integer()}
  defp registration_identity(%__MODULE__{} = registry, buffer_pid) do
    case Map.fetch(registry.ids, buffer_pid) do
      {:ok, existing_id} -> {existing_id, :existing, registry.next_id}
      :error -> {registry.next_id, :new, registry.next_id + 1}
    end
  end
end
