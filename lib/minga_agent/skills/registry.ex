defmodule MingaAgent.Skills.Registry do
  @moduledoc """
  Source-owned registry for extension-contributed skill paths.

  Global and project-local skills remain filesystem-discovered. Extension skill declarations are stored here so extension disable and reload can remove stale skill paths without rescanning running manifests.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Manifest

  @typedoc "Source that contributed skill paths."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Registry entry for one skill path."
  @type entry :: %{
          source: source(),
          id: String.t(),
          path: String.t()
        }

  @type state :: [entry()]

  @doc "Starts the skill registry."
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

  @doc "Registers a source-owned batch of skill paths. Same-source batches replace prior entries."
  @spec register_many(source(), [String.t()], keyword()) :: :ok
  def register_many(source, paths, opts \\ []) when is_list(paths) do
    server = Keyword.get(opts, :server, __MODULE__)
    root = Keyword.get(opts, :root)
    GenServer.call(server, {:register_many, source, paths, root})
  end

  @doc "Removes all skill paths owned by a source."
  @spec unregister_source(source()) :: :ok
  def unregister_source(source), do: unregister_source(__MODULE__, source)

  @doc false
  @spec unregister_source(GenServer.server(), source()) :: :ok
  def unregister_source(server, source) do
    GenServer.call(server, {:unregister_source, source})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Returns registered entries in deterministic registration order."
  @spec entries() :: [entry()]
  def entries, do: entries(__MODULE__)

  @doc false
  @spec entries(GenServer.server()) :: [entry()]
  def entries(server) do
    GenServer.call(server, :entries)
  catch
    :exit, _ -> []
  end

  @doc "Returns registered skill paths in deterministic registration order."
  @spec paths() :: [String.t()]
  def paths, do: paths(__MODULE__)

  @doc false
  @spec paths(GenServer.server()) :: [String.t()]
  def paths(server) do
    GenServer.call(server, :paths)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    Minga.Events.subscribe(:extension_agent_contributions_started)
    ContributionCleanup.register(:agent_skill_registry, &__MODULE__.unregister_source/1)
    {:ok, seed_from_running_extensions([])}
  end

  @impl true
  def handle_call({:register_many, source, paths, root}, _from, state) do
    entries = normalize_paths(source, paths, root)
    {:reply, :ok, replace_source(state, source, entries)}
  end

  def handle_call({:unregister_source, source}, _from, state) do
    {:reply, :ok, Enum.reject(state, &(&1.source == source))}
  end

  def handle_call(:entries, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:paths, _from, state) do
    {:reply, Enum.map(state, & &1.path), state}
  end

  @impl true
  def handle_info(
        {:minga_event, :extension_agent_contributions_started,
         %{source: source, root: root, manifest: %Manifest{} = manifest}},
        state
      ) do
    entries = normalize_paths(source, manifest.skills, root)
    {:noreply, replace_source(state, source, entries)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec seed_from_running_extensions(state()) :: state()
  defp seed_from_running_extensions(state) do
    if Process.whereis(Minga.Extension.Registry) do
      Minga.Extension.Registry.all()
      |> Enum.filter(fn {_name, entry} -> entry.status == :running and entry.manifest != nil end)
      |> Enum.reduce(state, fn {name, entry}, acc ->
        source = {:extension, name}

        replace_source(
          acc,
          source,
          normalize_paths(source, entry.manifest.skills, extension_root(entry))
        )
      end)
    else
      state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  @spec normalize_paths(source(), [String.t()], String.t() | nil) :: [entry()]
  defp normalize_paths(source, paths, root) do
    paths
    |> Enum.with_index()
    |> Enum.flat_map(fn {path, index} -> normalize_path(source, path, root, index) end)
  end

  @spec normalize_path(source(), term(), String.t() | nil, non_neg_integer()) :: [entry()]
  defp normalize_path(source, path, root, index) when is_binary(path) do
    [%{source: source, id: Integer.to_string(index), path: resolve_path(path, root)}]
  end

  defp normalize_path(_source, _path, _root, _index), do: []

  @spec resolve_path(String.t(), String.t() | nil) :: String.t()
  defp resolve_path(path, root) when is_binary(root) do
    if Path.type(path) == :absolute, do: path, else: Path.join(root, path)
  end

  defp resolve_path(path, _root), do: path

  @spec replace_source(state(), source(), [entry()]) :: state()
  defp replace_source(state, source, entries) do
    state
    |> Enum.reject(&(&1.source == source))
    |> Kernel.++(entries)
  end

  @spec extension_root(map()) :: String.t() | nil
  defp extension_root(%{path: path}) when is_binary(path), do: path

  defp extension_root(%{hex: %{app: app}}) when is_atom(app) do
    case :code.lib_dir(app) do
      path when is_list(path) -> List.to_string(path)
      _ -> nil
    end
  end

  defp extension_root(%{module: mod}) when is_atom(mod) and not is_nil(mod) do
    case :code.which(mod) do
      path when is_list(path) -> path |> List.to_string() |> Path.dirname() |> Path.dirname()
      _ -> nil
    end
  end

  defp extension_root(_entry), do: nil
end
