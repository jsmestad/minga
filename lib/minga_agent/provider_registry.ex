defmodule MingaAgent.ProviderRegistry do
  @moduledoc """
  Source-owned registry for agent provider declarations.

  The registry resolves provider ids to implementation modules while core session code keeps ownership of sessions, credentials, retries, costs, events, and cleanup. Sources may replace their own provider ids during reload, but cross-source duplicate ids fail deterministically.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup
  alias MingaAgent.Provider.Spec

  defmodule Entry do
    @moduledoc "Runtime registry entry for one provider."
    @enforce_keys [:spec, :enabled?]
    defstruct [:spec, :enabled?]

    @type t :: %__MODULE__{spec: Spec.t(), enabled?: boolean()}
  end

  @typedoc "Provider registry server."
  @type server :: GenServer.server()

  @typedoc "Source that owns provider declarations."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Registration failure reason."
  @type register_error ::
          {:duplicate_provider_id, String.t(), existing_source :: source(),
           attempted_source :: source()}
          | {:invalid_spec, term()}

  @type state :: %{String.t() => Entry.t()}

  @doc "Starts the provider registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    seed_builtin? = Keyword.get(opts, :seed_builtin?, name == __MODULE__)
    GenServer.start_link(__MODULE__, [name: name, seed_builtin?: seed_builtin?], name: name)
  end

  @doc "Registers or replaces a provider spec."
  @spec register(Spec.t() | keyword() | map()) :: :ok | {:error, register_error()}
  @spec register(server(), Spec.t() | keyword() | map()) :: :ok | {:error, register_error()}
  def register(spec), do: register(__MODULE__, spec)

  def register(server, %Spec{} = spec) do
    register_validated(server, Map.from_struct(spec))
  end

  def register(server, attrs) when is_list(attrs) or is_map(attrs) do
    register_validated(server, attrs)
  end

  @spec register_validated(server(), keyword() | map()) :: :ok | {:error, register_error()}
  defp register_validated(server, attrs) do
    case Spec.new(attrs) do
      {:ok, spec} -> GenServer.call(server, {:register, spec})
      {:error, reason} -> {:error, {:invalid_spec, reason}}
    end
  end

  @doc "Looks up an enabled provider by id."
  @spec lookup(String.t()) :: {:ok, Entry.t()} | {:error, :not_found | :disabled}
  @spec lookup(server(), String.t()) :: {:ok, Entry.t()} | {:error, :not_found | :disabled}
  def lookup(id), do: lookup(__MODULE__, id)

  def lookup(server, id) when is_binary(id), do: GenServer.call(server, {:lookup, id})

  @doc "Looks up a provider regardless of enabled state."
  @spec get(String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  @spec get(server(), String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get(id), do: get(__MODULE__, id)

  def get(server, id) when is_binary(id), do: GenServer.call(server, {:get, id})

  @doc "Lists all registered provider entries."
  @spec all() :: [Entry.t()]
  @spec all(server()) :: [Entry.t()]
  def all, do: all(__MODULE__)
  def all(server), do: GenServer.call(server, :all)

  @doc "Disables a provider for new sessions."
  @spec disable(String.t()) :: :ok | {:error, :not_found}
  @spec disable(server(), String.t()) :: :ok | {:error, :not_found}
  def disable(id), do: disable(__MODULE__, id)

  def disable(server, id) when is_binary(id),
    do: GenServer.call(server, {:set_enabled, id, false})

  @doc "Enables a provider for new sessions."
  @spec enable(String.t()) :: :ok | {:error, :not_found}
  @spec enable(server(), String.t()) :: :ok | {:error, :not_found}
  def enable(id), do: enable(__MODULE__, id)
  def enable(server, id) when is_binary(id), do: GenServer.call(server, {:set_enabled, id, true})

  @doc "Removes every provider contributed by a source."
  @spec unregister_source(source()) :: :ok
  @spec unregister_source(server(), source()) :: :ok
  def unregister_source(source), do: unregister_source(__MODULE__, source)

  def unregister_source(server, source) do
    GenServer.call(server, {:unregister_source, source})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Returns the built-in native provider spec."
  @spec native_spec() :: Spec.t()
  def native_spec do
    Spec.new!(
      source: :builtin,
      id: "native",
      module: MingaAgent.Providers.Native,
      display_name: "native",
      model_prefixes: ["anthropic:", "openai:", "ollama:", "groq:", "bedrock:"],
      capabilities: [:streaming, :tools, :mcp, :thinking, :model_switching],
      credential_requirements: [:llm]
    )
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    maybe_register_cleanup_callback(Keyword.get(opts, :name, __MODULE__))
    state = %{}

    state =
      if Keyword.get(opts, :seed_builtin?, false) do
        put_entry(state, native_spec())
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:register, %Spec{} = spec}, _from, state) do
    case can_register?(state, spec) do
      :ok -> {:reply, :ok, put_entry(state, spec)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:lookup, id}, _from, state) do
    reply =
      case Map.fetch(state, id) do
        {:ok, %Entry{enabled?: true} = entry} -> {:ok, entry}
        {:ok, %Entry{enabled?: false}} -> {:error, :disabled}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:get, id}, _from, state) do
    reply =
      case Map.fetch(state, id) do
        {:ok, entry} -> {:ok, entry}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:all, _from, state) do
    entries = state |> Map.values() |> Enum.sort_by(& &1.spec.id)
    {:reply, entries, state}
  end

  def handle_call({:set_enabled, id, enabled?}, _from, state) do
    case Map.fetch(state, id) do
      {:ok, entry} -> {:reply, :ok, Map.put(state, id, %{entry | enabled?: enabled?})}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unregister_source, source}, _from, state) do
    state = Map.reject(state, fn {_id, entry} -> entry.spec.source == source end)
    {:reply, :ok, state}
  end

  @spec maybe_register_cleanup_callback(server()) :: :ok
  defp maybe_register_cleanup_callback(__MODULE__) do
    Minga.Extension.ContributionCleanup.register(
      :agent_provider_registry,
      &__MODULE__.unregister_source/1
    )
  end

  defp maybe_register_cleanup_callback(_name), do: :ok

  @spec can_register?(state(), Spec.t()) :: :ok | {:error, register_error()}
  defp can_register?(state, %Spec{} = spec) do
    case Map.fetch(state, spec.id) do
      {:ok, %Entry{spec: %{source: source}}} when source != spec.source ->
        {:error, {:duplicate_provider_id, spec.id, source, spec.source}}

      _other ->
        :ok
    end
  end

  @spec put_entry(state(), Spec.t()) :: state()
  defp put_entry(state, %Spec{} = spec) do
    Map.put(state, spec.id, %Entry{spec: spec, enabled?: true})
  end
end
