defmodule Minga.Extension.ContributionCleanup do
  @moduledoc """
  Source-owned contribution cleanup coordinator.

  The extension supervisor lives in the core `Minga.*` layer, so it cannot depend on editor presentation modules directly. Editor-layer registries register cleanup callbacks here when they accept source-owned contributions. The supervisor calls this module with a source, and the coordinator cleans core registries plus any registered higher-layer callbacks without creating compile-time upward dependencies.
  """

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:extension, atom()}

  @typedoc "Cleanup callback invoked with a source identifier."
  @type cleanup_fun :: (contribution_source() -> :ok)

  @typedoc "Cleanup options with injectable test registries."
  @type cleanup_opts :: [command_registry: GenServer.server(), keymap: GenServer.server()]

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
  @spec unregister_source(contribution_source(), cleanup_opts()) :: :ok
  def unregister_source(source, opts \\ []) do
    command_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)

    Minga.Command.Registry.unregister_source(command_registry, source)
    Minga.Keymap.Active.unregister_source(keymap, source)
    Minga.Keymap.Scope.unregister_source(source)
    Minga.Language.Registry.unregister_source(source)
    Minga.Tool.Recipe.Registry.unregister_source(source)
    Minga.Config.ModelineSegments.unregister_source(source)

    callbacks()
    |> Map.values()
    |> Enum.each(&safe_cleanup(&1, source))

    :ok
  end

  @spec callbacks() :: %{atom() => cleanup_fun()}
  defp callbacks, do: :persistent_term.get(@callbacks_key, %{})

  @spec safe_cleanup(cleanup_fun(), contribution_source()) :: :ok
  defp safe_cleanup(fun, source) do
    fun.(source)
  rescue
    e ->
      Minga.Log.warning(
        :config,
        "Contribution cleanup failed for #{inspect(source)}: #{Exception.message(e)}"
      )

      :ok
  end
end
