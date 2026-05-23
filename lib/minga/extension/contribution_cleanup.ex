defmodule Minga.Extension.ContributionCleanup do
  @moduledoc """
  Source-owned contribution cleanup coordinator.

  The extension supervisor lives in the core `Minga.*` layer, so it cannot depend on editor presentation modules directly. Editor-layer registries register cleanup callbacks here when they accept source-owned contributions. The supervisor calls this module with a source, and the coordinator cleans core registries plus any registered higher-layer callbacks without creating compile-time upward dependencies.
  """

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:extension, atom()}

  @typedoc "Cleanup callback invoked with a source identifier."
  @type cleanup_fun :: (contribution_source() -> :ok | {:error, term()})

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
          callbacks: %{atom() => cleanup_fun()}
        ]

  @callbacks_key {__MODULE__, :callbacks}

  @doc "Registers a cleanup callback for a contribution family."
  @spec register(atom(), cleanup_fun()) :: :ok
  def register(name, fun) when is_atom(name) and is_function(fun, 1) do
    callbacks = Map.put(callbacks(), name, fun)
    :persistent_term.put(@callbacks_key, callbacks)
    :ok
  end

  @doc "Unregisters a cleanup callback. Mostly useful for tests."
  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name) do
    callbacks = Map.delete(callbacks(), name)
    :persistent_term.put(@callbacks_key, callbacks)
    :ok
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

  @spec cleanup_families(GenServer.server(), GenServer.server(), %{atom() => cleanup_fun()}, contribution_source()) ::
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
      |> Enum.sort_by(fn {family, _fun} -> Atom.to_string(family) end)
      |> Enum.map(fn {family, fun} -> {family, fn -> fun.(source) end} end)
    )
  end

  @spec callbacks() :: %{atom() => cleanup_fun()}
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
