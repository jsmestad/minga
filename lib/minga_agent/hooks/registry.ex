defmodule MingaAgent.Hooks.Registry do
  @moduledoc """
  Source-owned registry for extension-contributed agent hooks.

  User config hooks still live on `MingaAgent.Config`. Extension hooks are normalized here so session lifecycle hooks and provider tool hooks read the same source-aware view, and extension cleanup can remove a whole source deterministically.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Manifest
  alias MingaAgent.Hooks.Hook

  @typedoc "Source that contributed hooks."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Registry entry for one normalized hook."
  @type entry :: %{
          source: source(),
          id: String.t(),
          hook: Hook.t()
        }

  @type state :: [entry()]

  @doc "Starts the hook registry."
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

  @doc "Registers a source-owned batch of raw hook declarations. Same-source batches replace prior entries."
  @spec register_many(source(), [{atom() | String.t(), keyword()}], keyword()) :: :ok
  def register_many(source, hooks, opts \\ []) when is_list(hooks) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:register_many, source, hooks, Keyword.get(opts, :module)})
  end

  @doc "Removes all hooks owned by a source."
  @spec unregister_source(source()) :: :ok
  def unregister_source(source), do: unregister_source(__MODULE__, source)

  @doc false
  @spec unregister_source(GenServer.server(), source()) :: :ok
  def unregister_source(server, source) do
    GenServer.call(server, {:unregister_source, source})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Returns all normalized hooks in registration order."
  @spec all() :: [Hook.t()]
  def all, do: all(__MODULE__)

  @doc false
  @spec all(GenServer.server()) :: [Hook.t()]
  def all(server) do
    GenServer.call(server, :all)
  catch
    :exit, _ -> []
  end

  @doc "Returns all registry entries in registration order."
  @spec entries() :: [entry()]
  def entries, do: entries(__MODULE__)

  @doc false
  @spec entries(GenServer.server()) :: [entry()]
  def entries(server) do
    GenServer.call(server, :entries)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    Minga.Events.subscribe(:extension_agent_contributions_started)
    ContributionCleanup.register(:agent_hook_registry, &__MODULE__.unregister_source/1)
    {:ok, seed_from_running_extensions([])}
  end

  @impl true
  def handle_call({:register_many, source, hooks, module}, _from, state) do
    entries = normalize_hooks(source, hooks, module)
    state = replace_source(state, source, entries)
    {:reply, :ok, state}
  end

  def handle_call({:unregister_source, source}, _from, state) do
    {:reply, :ok, Enum.reject(state, &(&1.source == source))}
  end

  def handle_call(:all, _from, state) do
    {:reply, Enum.map(state, & &1.hook), state}
  end

  def handle_call(:entries, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(
        {:minga_event, :extension_agent_contributions_started,
         %{source: source, module: module, manifest: %Manifest{} = manifest}},
        state
      ) do
    entries = normalize_hooks(source, manifest.hooks, module)
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
        replace_source(acc, source, normalize_hooks(source, entry.manifest.hooks, entry.module))
      end)
    else
      state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  @spec normalize_hooks(source(), [{atom() | String.t(), keyword()}], module() | nil) :: [entry()]
  defp normalize_hooks(source, hooks, module) do
    hooks
    |> Enum.with_index()
    |> Enum.flat_map(fn {{event, opts}, index} ->
      normalize_hook(source, event, opts, module, index)
    end)
  end

  @spec normalize_hook(
          source(),
          atom() | String.t(),
          keyword(),
          module() | nil,
          non_neg_integer()
        ) :: [entry()]
  defp normalize_hook(source, event, opts, module, index) when is_list(opts) do
    hook_opts =
      opts
      |> Keyword.put(:event, event)
      |> maybe_put_extension_source(source)
      |> maybe_put_extension_module(module)

    case Hook.normalize(hook_opts) do
      {:ok, hook} ->
        [%{source: source, id: Integer.to_string(index), hook: hook}]

      {:error, reason} ->
        Minga.Log.warning(:agent, "Extension hook normalization failed: #{reason}")
        []
    end
  end

  defp normalize_hook(_source, _event, _opts, _module, _index), do: []

  @spec maybe_put_extension_source(keyword(), source()) :: keyword()
  defp maybe_put_extension_source(opts, {:extension, name}),
    do: Keyword.put(opts, :extension_source, name)

  defp maybe_put_extension_source(opts, _source), do: opts

  @spec maybe_put_extension_module(keyword(), module() | nil) :: keyword()
  defp maybe_put_extension_module(opts, module) when is_atom(module),
    do: Keyword.put(opts, :extension_module, module)

  defp maybe_put_extension_module(opts, _module), do: opts

  @spec replace_source(state(), source(), [entry()]) :: state()
  defp replace_source(state, source, entries) do
    state
    |> Enum.reject(&(&1.source == source))
    |> Kernel.++(entries)
  end
end
