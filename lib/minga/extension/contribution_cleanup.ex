defmodule Minga.Extension.ContributionCleanup do
  @moduledoc """
  Source-owned contribution cleanup coordinator.

  The extension supervisor lives in the core `Minga.*` layer, so it cannot depend on editor presentation modules directly. Editor-layer registries register cleanup callbacks here when they accept source-owned contributions. The supervisor calls this module with a source, and the coordinator cleans core registries plus any registered higher-layer callbacks without creating compile-time upward dependencies.

  Callback registration arrives from many processes while they start, so this module also runs as the sole writer of the callback map. The GenServer serializes every `register/2`, `register_contextual/2`, and `unregister/1` and publishes the result through `:persistent_term`; two concurrent registrations can no longer overwrite each other. Cleanup reads the published map directly and runs the callbacks in the calling process, never inside the owner, so a callback that registers another callback cannot deadlock. The owner starts first under `Minga.Supervisor` and adopts the published map when it restarts.
  """

  use GenServer

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:bundle, atom()} | {:extension, atom()}

  @typedoc "Cleanup callback invoked with a source identifier."
  @type cleanup_fun :: (contribution_source() -> :ok | {:error, term()})

  @typedoc "Targeted lifecycle callback invoked with source-specific authority."
  @type contextual_cleanup_fun ::
          (contribution_source(), context :: term() -> :ok | {:error, term()})

  @typep registered_cleanup_fun :: cleanup_fun() | contextual_cleanup_fun()

  @typedoc "Cleanup failure reported for one family."
  @type cleanup_failure :: %{
          family: atom(),
          source: contribution_source(),
          reason: term()
        }

  @typedoc "Cleanup options with injectable test registries."
  @type cleanup_opts :: [
          command_registry: GenServer.server(),
          keymap: GenServer.server(),
          callbacks: %{atom() => registered_cleanup_fun()},
          context: term()
        ]

  @callbacks_key {__MODULE__, :callbacks}

  @doc "Starts the sole writer of the cleanup callback map."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Registers a cleanup callback for a contribution family."
  @spec register(atom(), cleanup_fun()) :: :ok
  def register(name, fun) when is_atom(name) and is_function(fun, 1) do
    put_callback(name, fun)
  end

  @doc "Registers a targeted lifecycle callback that requires explicit authority context."
  @spec register_contextual(atom(), contextual_cleanup_fun()) :: :ok
  def register_contextual(name, fun) when is_atom(name) and is_function(fun, 2) do
    put_callback(name, fun)
  end

  @doc "Unregisters a cleanup callback. Mostly useful for tests."
  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name), do: GenServer.call(__MODULE__, {:unregister, name})

  @doc false
  @spec merge_callbacks(%{atom() => registered_cleanup_fun()}) ::
          %{atom() => registered_cleanup_fun()}
  def merge_callbacks(overrides) when is_map(overrides), do: Map.merge(callbacks(), overrides)

  @doc "Runs one targeted source finalizer before runtime termination."
  @spec finalize_source(contribution_source(), atom(), cleanup_opts()) ::
          :ok | {:error, cleanup_failure()}
  def finalize_source(source, family, opts \\ []) when is_atom(family) do
    cbs = Keyword.get(opts, :callbacks, callbacks())

    context = Keyword.get(opts, :context)

    case Map.fetch(cbs, family) do
      {:ok, fun} ->
        run_cleanup_family(family, source, fn -> invoke_targeted(fun, source, context) end)

      :error ->
        :ok
    end
  end

  @doc "Removes all contributions owned by a source."
  @spec unregister_source(contribution_source(), cleanup_opts()) ::
          :ok | {:error, [cleanup_failure()]}
  def unregister_source(source, opts \\ []) do
    command_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)
    cbs = Keyword.get(opts, :callbacks, callbacks())

    cleanup_families(command_registry, keymap, cbs, source)
    |> Enum.reduce({:ok, []}, fn {family, fun}, {status, failures} ->
      case run_cleanup_family(family, source, fun) do
        :ok -> {status, failures}
        {:error, failure} -> {:error, [failure | failures]}
      end
    end)
    |> case do
      {:ok, _failures} -> :ok
      {:error, failures} -> {:error, Enum.reverse(failures)}
    end
  end

  @spec cleanup_families(
          GenServer.server(),
          GenServer.server(),
          %{atom() => cleanup_fun()},
          contribution_source()
        ) ::
          [{atom(), (-> term())}]
  defp cleanup_families(command_registry, keymap, cbs, source) do
    [
      {:command_registry,
       fn -> Minga.Command.Registry.unregister_source(command_registry, source) end},
      {:keymap_active, fn -> Minga.Keymap.Active.unregister_source(keymap, source) end},
      {:keymap_scope, fn -> Minga.Keymap.Scope.unregister_source(source) end},
      {:language_registry, fn -> Minga.Language.Registry.unregister_source(source) end},
      {:tool_recipe_registry, fn -> Minga.Tool.Recipe.Registry.unregister_source(source) end},
      {:modeline_segments, fn -> Minga.Config.ModelineSegments.unregister_source(source) end}
    ]
    |> Kernel.++(
      cbs
      |> Enum.filter(fn {family, fun} ->
        is_function(fun, 1) and include_full_cleanup_family?(source, family)
      end)
      |> Enum.sort_by(fn {family, _fun} -> Atom.to_string(family) end)
      |> Enum.map(fn {family, fun} -> {family, fn -> fun.(source) end} end)
    )
  end

  @spec include_full_cleanup_family?(contribution_source(), atom()) :: boolean()
  defp include_full_cleanup_family?({:extension, _name}, family),
    do: family not in [:editor_effects, :editor_extension_unload]

  defp include_full_cleanup_family?(_source, _family), do: true

  @spec put_callback(atom(), registered_cleanup_fun()) :: :ok
  defp put_callback(name, fun), do: GenServer.call(__MODULE__, {:put, name, fun})

  @impl true
  @spec init(:ok) :: {:ok, %{atom() => registered_cleanup_fun()}}
  def init(:ok), do: {:ok, callbacks()}

  @impl true
  @spec handle_call(
          {:put, atom(), registered_cleanup_fun()} | {:unregister, atom()},
          GenServer.from(),
          %{atom() => registered_cleanup_fun()}
        ) :: {:reply, :ok, %{atom() => registered_cleanup_fun()}}
  def handle_call({:put, name, fun}, _from, callbacks) do
    {:reply, :ok, publish_changed(callbacks, Map.put(callbacks, name, fun))}
  end

  def handle_call({:unregister, name}, _from, callbacks) do
    {:reply, :ok, publish_changed(callbacks, Map.delete(callbacks, name))}
  end

  # Every :persistent_term write triggers a global literal-area scan.
  # Registrations often repeat an identical callback, so an unchanged map is not republished.
  @spec publish_changed(map(), map()) :: map()
  defp publish_changed(callbacks, callbacks), do: callbacks

  defp publish_changed(_previous, updated) do
    :persistent_term.put(@callbacks_key, updated)
    updated
  end

  @spec invoke_targeted(registered_cleanup_fun(), contribution_source(), term()) ::
          :ok | {:error, term()}
  defp invoke_targeted(fun, source, _context) when is_function(fun, 1), do: fun.(source)
  defp invoke_targeted(fun, source, context) when is_function(fun, 2), do: fun.(source, context)

  @spec callbacks() :: %{atom() => registered_cleanup_fun()}
  defp callbacks, do: :persistent_term.get(@callbacks_key, %{})

  @spec run_cleanup_family(atom(), contribution_source(), (-> term())) ::
          :ok | {:error, cleanup_failure()}
  defp run_cleanup_family(family, source, fun) do
    case fun.() do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, %{family: family, source: source, reason: reason}}

      other ->
        {:error, %{family: family, source: source, reason: {:unexpected_return, other}}}
    end
  rescue
    e ->
      {:error, %{family: family, source: source, reason: {:exception, Exception.message(e)}}}
  catch
    kind, reason ->
      {:error, %{family: family, source: source, reason: {kind, reason}}}
  end
end
