defmodule MingaAgent.MCP.ServerRegistry do
  @moduledoc """
  Source-owned registry for MCP server declarations.

  This is declaration metadata, not the per-provider live client registry. Native providers read this registry to build their MCP config list and keep active sessions synchronized when extension MCP contributions are removed or reloaded.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Manifest
  alias MingaAgent.MCP.ServerConfig

  @typedoc "Source that contributed MCP server declarations."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Registry entry for one MCP server declaration."
  @type entry :: %{
          source: source(),
          id: String.t(),
          config: ServerConfig.t()
        }

  @type state :: [entry()]

  @doc "Starts the MCP server declaration registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc "Registers a source-owned batch of MCP declarations. Same-source batches replace prior entries."
  @spec register_many(source(), [{atom() | String.t(), keyword()}], keyword()) :: :ok
  def register_many(source, servers, opts \\ []) when is_list(servers) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:register_many, source, servers})
  end

  @doc "Removes all MCP server declarations owned by a source."
  @spec unregister_source(source()) :: :ok
  def unregister_source(source), do: unregister_source(__MODULE__, source)

  @doc false
  @spec unregister_source(GenServer.server(), source()) :: :ok
  def unregister_source(server, source) do
    GenServer.call(server, {:unregister_source, source})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Returns registry entries in deterministic registration order."
  @spec entries() :: [entry()]
  def entries, do: entries(__MODULE__)

  @doc false
  @spec entries(GenServer.server()) :: [entry()]
  def entries(server) do
    GenServer.call(server, :entries)
  catch
    :exit, _ -> []
  end

  @doc "Returns all registered MCP configs in deterministic registration order."
  @spec configs() :: [ServerConfig.t()]
  def configs, do: configs(__MODULE__)

  @doc false
  @spec configs(GenServer.server()) :: [ServerConfig.t()]
  def configs(server) do
    GenServer.call(server, :configs)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    Minga.Events.subscribe(:extension_agent_contributions_started)
    ContributionCleanup.register(:agent_mcp_server_registry, &__MODULE__.unregister_source/1)
    {:ok, seed_from_running_extensions([])}
  end

  @impl true
  def handle_call({:register_many, source, servers}, _from, state) do
    state = register_source_batch(state, source, servers)
    broadcast_changed(source)
    {:reply, :ok, state}
  end

  def handle_call({:unregister_source, source}, _from, state) do
    state = Enum.reject(state, &(&1.source == source))
    broadcast_changed(source)
    {:reply, :ok, state}
  end

  def handle_call(:entries, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:configs, _from, state) do
    {:reply, Enum.map(state, & &1.config), state}
  end

  @impl true
  def handle_info(
        {:minga_event, :extension_agent_contributions_started,
         %{source: source, manifest: %Manifest{} = manifest}},
        state
      ) do
    state = register_source_batch(state, source, manifest.mcp_servers)
    broadcast_changed(source)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec seed_from_running_extensions(state()) :: state()
  defp seed_from_running_extensions(state) do
    if Process.whereis(Minga.Extension.Registry) do
      Minga.Extension.Registry.all()
      |> Enum.filter(fn {_name, entry} -> entry.status == :running and entry.manifest != nil end)
      |> Enum.reduce(state, fn {name, entry}, acc ->
        register_source_batch(acc, {:extension, name}, entry.manifest.mcp_servers)
      end)
    else
      state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  @spec register_source_batch(state(), source(), [{atom() | String.t(), keyword()}]) :: state()
  defp register_source_batch(state, source, servers) do
    state_without_source = Enum.reject(state, &(&1.source == source))
    existing_names = MapSet.new(Enum.map(state_without_source, & &1.config.name))

    {entries, _seen} =
      servers
      |> Enum.with_index()
      |> Enum.reduce({[], existing_names}, fn {{name, opts}, index}, {entries, seen} ->
        case normalize_server(source, name, opts, index) do
          {:ok, entry} -> maybe_add_entry(entries, seen, entry)
          :error -> {entries, seen}
        end
      end)

    state_without_source ++ Enum.reverse(entries)
  end

  @spec normalize_server(source(), atom() | String.t(), keyword(), non_neg_integer()) ::
          {:ok, entry()} | :error
  defp normalize_server(source, name, opts, index) when is_list(opts) do
    server_map =
      opts
      |> Keyword.put(:name, server_id(name))
      |> Keyword.put(:source, source)
      |> Map.new()

    case ServerConfig.normalize(server_map) do
      {:ok, %ServerConfig{} = config} ->
        {:ok, %{source: source, id: Integer.to_string(index), config: config}}

      {:error, reason} ->
        Minga.Log.warning(:agent, "Extension MCP server normalization failed: #{reason}")
        :error
    end
  end

  defp normalize_server(_source, _name, _opts, _index), do: :error

  @spec maybe_add_entry([entry()], MapSet.t(String.t()), entry()) ::
          {[entry()], MapSet.t(String.t())}
  defp maybe_add_entry(entries, seen, %{config: %ServerConfig{name: name}} = entry) do
    if MapSet.member?(seen, name) do
      Minga.Log.warning(:agent, "Duplicate MCP server name ignored: #{name}")
      {entries, seen}
    else
      {[entry | entries], MapSet.put(seen, name)}
    end
  end

  @spec server_id(atom() | String.t()) :: String.t()
  defp server_id(name) when is_atom(name), do: Atom.to_string(name)
  defp server_id(name) when is_binary(name), do: name

  @spec broadcast_changed(source()) :: :ok
  defp broadcast_changed(source) do
    Minga.Events.broadcast(:agent_mcp_servers_changed, %{source: source})
  end
end
