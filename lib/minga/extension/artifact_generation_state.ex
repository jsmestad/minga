defmodule Minga.Extension.ArtifactGenerationState do
  @moduledoc """
  VM-generation storage for extension artifact provenance.

  Admission snapshots live in `persistent_term`, so restarting this process or
  its containing supervisor does not reopen an empty generation while extension
  modules remain loaded. Snapshots contain only durable provenance and lifecycle
  status; process identifiers, monitors, callers, and attempt tokens are never
  retained as authority across a restart.
  """

  use GenServer

  @storage_prefix {__MODULE__, :admission_snapshot}
  @production_persistence_key :production

  @type persistence_key :: term()
  @type admission_state :: map() | nil
  @type state :: %{
          admission: admission_state(),
          persistence_key: persistence_key()
        }

  @doc "Starts a VM-generation state owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Reads the sanitized admission snapshot for this VM generation."
  @spec fetch(GenServer.server()) :: {:ok, admission_state()} | {:error, term()}
  def fetch(server \\ __MODULE__) do
    {:ok, GenServer.call(server, :fetch)}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Persists a sanitized admission snapshot after one serialized transition."
  @spec store(GenServer.server(), map()) :: :ok | {:error, term()}
  def store(server \\ __MODULE__, admission) when is_map(admission) do
    GenServer.call(server, {:store, admission})
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  @spec reset_for_test(persistence_key()) :: :ok | {:error, :production_persistence_key}
  def reset_for_test(@production_persistence_key), do: {:error, :production_persistence_key}

  def reset_for_test(persistence_key) do
    :persistent_term.erase(storage_key(persistence_key))
    :ok
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    persistence_key =
      Keyword.get_lazy(opts, :persistence_key, fn -> default_persistence_key(name) end)

    admission = :persistent_term.get(storage_key(persistence_key), nil)
    {:ok, %{admission: admission, persistence_key: persistence_key}}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call(:fetch, _from, state), do: {:reply, state.admission, state}

  def handle_call({:store, admission}, _from, state) do
    sanitized = sanitize_admission(admission)
    :persistent_term.put(storage_key(state.persistence_key), sanitized)
    {:reply, :ok, %{state | admission: sanitized}}
  end

  @spec default_persistence_key(GenServer.name() | nil) :: persistence_key()
  defp default_persistence_key(__MODULE__), do: @production_persistence_key
  defp default_persistence_key(nil), do: make_ref()
  defp default_persistence_key(name), do: {:registered_name, name}

  @spec storage_key(persistence_key()) :: term()
  defp storage_key(persistence_key), do: {@storage_prefix, persistence_key}

  @spec sanitize_admission(map()) :: map()
  defp sanitize_admission(admission) do
    %{
      sources: sanitize_sources(Map.get(admission, :sources, %{})),
      module_sources: Map.get(admission, :module_sources, %{}),
      sealed?: Map.get(admission, :sealed?, false),
      failed?: Map.get(admission, :failed?, false)
    }
  end

  @spec sanitize_sources(map()) :: map()
  defp sanitize_sources(sources) do
    Map.new(sources, fn {source, record} -> {source, sanitize_source_record(record)} end)
  end

  @spec sanitize_source_record(map()) :: map()
  defp sanitize_source_record(record) do
    record
    |> Map.take([
      :fingerprint,
      :source_fingerprint,
      :modules,
      :load_modules,
      :adopted_modules
    ])
    |> Map.put(:status, sanitize_status(Map.fetch!(record, :status)))
  end

  @spec sanitize_status(term()) :: :committed | :failed | {:pending, :claimed | :loading}
  defp sanitize_status(:committed), do: :committed
  defp sanitize_status(:failed), do: :failed

  defp sanitize_status({:pending, %{phase: phase}}) when phase in [:claimed, :loading],
    do: {:pending, phase}

  defp sanitize_status({:pending, phase}) when phase in [:claimed, :loading],
    do: {:pending, phase}
end
