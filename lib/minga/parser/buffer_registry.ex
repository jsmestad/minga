defmodule Minga.Parser.BufferRegistry do
  @moduledoc """
  Pure identity and lifecycle registry owned by `Minga.Parser.Manager`.
  """

  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferRegistration

  @type meta :: BufferRegistration.t()
  @type register_status :: :new | :existing | {:replaced, pos_integer()}
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

  @doc "Registers a buffer, preserving identity only while its inert configuration is unchanged."
  @spec register(t(), pid(), BufferConfig.t(), integer()) ::
          {pos_integer(), register_status(), t()}
  def register(%__MODULE__{} = registry, buffer_pid, %BufferConfig{} = config, now) do
    case Map.fetch(registry.entries, buffer_pid) do
      {:ok, %BufferRegistration{config: ^config} = existing} ->
        updated = %{registry | last_active_at: Map.put(registry.last_active_at, buffer_pid, now)}
        {existing.id, :existing, updated}

      {:ok, %BufferRegistration{id: old_id}} ->
        replace_registration(registry, buffer_pid, config, old_id, now)

      :error ->
        insert_registration(registry, buffer_pid, config, now)
    end
  end

  @doc "Records the process monitor owned by the parser manager."
  @spec put_monitor(t(), pid(), reference()) :: t()
  def put_monitor(%__MODULE__{} = registry, buffer_pid, monitor_ref) do
    %{registry | monitors: Map.put(registry.monitors, buffer_pid, monitor_ref)}
  end

  @doc "Returns whether a DOWN message belongs to the current monitor."
  @spec monitored?(t(), pid(), reference()) :: boolean()
  def monitored?(%__MODULE__{monitors: monitors}, buffer_pid, ref),
    do: Map.get(monitors, buffer_pid) == ref

  @doc "Returns a registration by PID."
  @spec fetch(t(), pid()) :: {:ok, meta()} | :error
  def fetch(%__MODULE__{entries: entries}, buffer_pid), do: Map.fetch(entries, buffer_pid)

  @doc "Replaces an existing registration; unknown PIDs are ignored."
  @spec put(t(), pid(), meta()) :: t()
  def put(%__MODULE__{} = registry, buffer_pid, %BufferRegistration{} = registration) do
    if Map.has_key?(registry.entries, buffer_pid) do
      %{registry | entries: Map.put(registry.entries, buffer_pid, registration)}
    else
      registry
    end
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

  @doc "Allocates the next manager-owned parser version."
  @spec next_parse_version(t()) :: {pos_integer(), t()}
  def next_parse_version(%__MODULE__{} = registry) do
    version = registry.parse_version + 1
    {version, %{registry | parse_version: version}}
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

  @doc "Unregisters a buffer and returns its former parser ID and monitor."
  @spec unregister(t(), pid()) :: {pos_integer() | nil, reference() | nil, t()}
  def unregister(%__MODULE__{} = registry, buffer_pid) do
    {buffer_id, ids} = Map.pop(registry.ids, buffer_pid)
    {monitor_ref, monitors} = Map.pop(registry.monitors, buffer_pid)

    updated = %{
      registry
      | entries: Map.delete(registry.entries, buffer_pid),
        ids: ids,
        pids: delete_reverse_id(registry.pids, buffer_id),
        last_active_at: Map.delete(registry.last_active_at, buffer_pid),
        monitors: monitors
    }

    {buffer_id, monitor_ref, updated}
  end

  @doc "Evicts stale unprotected buffers and returns their identities."
  @spec evict_inactive(t(), [pid()], non_neg_integer(), integer()) ::
          {[{pid(), pos_integer(), reference() | nil}], t()}
  def evict_inactive(%__MODULE__{} = registry, protected_pids, ttl_ms, now) do
    protected = MapSet.new(protected_pids)

    stale_pids =
      registry.last_active_at
      |> Enum.filter(fn {pid, active_at} ->
        now - active_at > ttl_ms and not MapSet.member?(protected, pid)
      end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(stale_pids, {[], registry}, fn pid, {evicted, acc} ->
      {id, ref, acc} = unregister(acc, pid)
      {[{pid, id, ref} | evicted], acc}
    end)
    |> then(fn {evicted, updated} -> {Enum.reverse(evicted), updated} end)
  end

  @doc "Returns all registrations."
  @spec entries(t()) :: %{pid() => meta()}
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc "Returns the number of registrations."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{entries: entries}), do: map_size(entries)

  @doc "Resets parser versions and marks every registration for full resync."
  @spec restart_all(t()) :: t()
  def restart_all(%__MODULE__{} = registry) do
    entries =
      Map.new(registry.entries, fn {pid, registration} ->
        {pid, BufferRegistration.restart(registration)}
      end)

    %{registry | entries: entries, parse_version: 0}
  end

  @spec delete_reverse_id(%{pos_integer() => pid()}, pos_integer() | nil) :: %{
          pos_integer() => pid()
        }
  defp delete_reverse_id(pids, nil), do: pids
  defp delete_reverse_id(pids, buffer_id), do: Map.delete(pids, buffer_id)

  @spec insert_registration(t(), pid(), BufferConfig.t(), integer()) ::
          {pos_integer(), :new, t()}
  defp insert_registration(registry, buffer_pid, config, now) do
    buffer_id = registry.next_id
    registration = BufferRegistration.new(buffer_id, config, make_ref())

    updated = %{
      registry
      | entries: Map.put(registry.entries, buffer_pid, registration),
        ids: Map.put(registry.ids, buffer_pid, buffer_id),
        pids: Map.put(registry.pids, buffer_id, buffer_pid),
        next_id: buffer_id + 1,
        last_active_at: Map.put(registry.last_active_at, buffer_pid, now)
    }

    {buffer_id, :new, updated}
  end

  @spec replace_registration(t(), pid(), BufferConfig.t(), pos_integer(), integer()) ::
          {pos_integer(), {:replaced, pos_integer()}, t()}
  defp replace_registration(registry, buffer_pid, config, old_id, now) do
    buffer_id = registry.next_id
    registration = BufferRegistration.new(buffer_id, config, make_ref())

    updated = %{
      registry
      | entries: Map.put(registry.entries, buffer_pid, registration),
        ids: Map.put(registry.ids, buffer_pid, buffer_id),
        pids: registry.pids |> Map.delete(old_id) |> Map.put(buffer_id, buffer_pid),
        next_id: buffer_id + 1,
        last_active_at: Map.put(registry.last_active_at, buffer_pid, now)
    }

    {buffer_id, {:replaced, old_id}, updated}
  end
end
