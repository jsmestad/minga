defmodule Minga.Extension.CallbackRegistry do
  @moduledoc """
  Extension-only registry for declarative runtime editor callbacks.

  Registration derives the extension source from lifecycle ownership and checks
  callback modules against the source's admitted artifact inventory. Core and
  config callbacks are intentionally not stored here; they execute directly in
  the layer that owns them.
  """

  use GenServer

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ContributionCleanup

  @table __MODULE__
  @supported_families [:buffer_saved, :editor_action, :source_unload]

  @typedoc "Named registry process and ETS table."
  @type registry :: atom()

  @typedoc "Runtime editor callback category available to extensions."
  @type family :: :buffer_saved | :editor_action | :source_unload

  @typedoc "An extension source that owns a registered callback."
  @type source :: {:extension, atom()}

  @typedoc "Options reserved for lifecycle-owned extension registration."
  @type lifecycle_opts :: [
          registry: registry(),
          artifact_admission: GenServer.server()
        ]

  @typedoc "A callback returned in deterministic dispatch order."
  @type callback :: {source(), module()}

  @doc "Starts a callback registry and its protected ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @table)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the production registry table name."
  @spec default_table() :: registry()
  def default_table, do: @table

  @doc false
  @spec register_extension(
          atom(),
          [Minga.Extension.editor_event_handler_spec()],
          lifecycle_opts()
        ) ::
          :ok | {:error, term()}
  def register_extension(name, schema, opts \\ [])
      when is_atom(name) and is_list(schema) and is_list(opts) do
    registry = Keyword.get(opts, :registry, @table)
    admission = Keyword.get(opts, :artifact_admission, ArtifactAdmission)

    call_registry(registry, {:register_extension, {:extension, name}, schema, admission})
  end

  @doc "Removes every callback owned by an extension source."
  @spec unregister_source(source(), registry()) :: :ok
  def unregister_source(source, registry \\ @table) do
    case call_registry(registry, {:unregister_source, source}) do
      :ok -> :ok
      {:error, :registry_not_started} -> :ok
    end
  end

  @doc "Returns extension callbacks for a family in deterministic priority order."
  @spec callbacks(family(), registry()) :: [callback()]
  def callbacks(family, registry \\ @table)
      when family in @supported_families and is_atom(registry) do
    case :ets.whereis(registry) do
      :undefined -> []
      _tid -> callback_entries(registry, family)
    end
  end

  @doc "Returns one extension source's callbacks in deterministic priority order."
  @spec callbacks_for_source(family(), source(), registry()) :: [callback()]
  def callbacks_for_source(family, source, registry \\ @table)
      when family in @supported_families and is_atom(registry) do
    family
    |> callbacks(registry)
    |> Enum.filter(fn {callback_source, _callback} -> callback_source == source end)
  end

  @impl true
  @spec init(keyword()) :: {:ok, registry()}
  def init(opts) do
    table = Keyword.get(opts, :name, @table)
    :ets.new(table, [:named_table, :ordered_set, :protected, read_concurrency: true])

    if table == @table do
      ContributionCleanup.register(:extension_callbacks, fn
        {:extension, _name} = source -> unregister_source(source, table)
        _source -> :ok
      end)
    end

    {:ok, table}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), registry()) :: {:reply, term(), registry()}
  def handle_call({:register_extension, source, schema, admission}, _from, table) do
    result = register_extension_schema(table, source, schema, admission)
    {:reply, result, table}
  end

  def handle_call({:unregister_source, source}, _from, table) do
    :ets.match_delete(table, {:_, source, :_})
    {:reply, :ok, table}
  end

  @spec register_extension_schema(registry(), source(), [term()], GenServer.server()) ::
          :ok | {:error, term()}
  defp register_extension_schema(table, source, schema, admission) do
    with {:ok, owned_modules} <- source_modules(source, admission),
         {:ok, declarations} <- validate_schema(schema, owned_modules) do
      Enum.each(declarations, fn {callback, families, priority} ->
        Enum.each(Enum.uniq(families), &put_callback(table, source, &1, callback, priority))
      end)

      :ok
    end
  end

  @spec source_modules(source(), GenServer.server()) ::
          {:ok, MapSet.t(module())} | {:error, term()}
  defp source_modules(source, admission) do
    case ArtifactAdmission.source_modules(source, server: admission) do
      {:ok, [_module | _rest] = modules} -> {:ok, MapSet.new(modules)}
      {:ok, []} -> {:error, {:source_artifact_unavailable, source}}
      :error -> {:error, {:source_artifact_unavailable, source}}
    end
  end

  @spec validate_schema([term()], MapSet.t(module())) ::
          {:ok, [{module(), [family()], integer()}]} | {:error, term()}
  defp validate_schema(schema, owned_modules) do
    schema
    |> Enum.reduce_while({:ok, []}, fn declaration, {:ok, declarations} ->
      case validate_declaration(declaration, owned_modules) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | declarations]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_declarations()
  end

  @spec reverse_declarations({:ok, [term()]} | {:error, term()}) ::
          {:ok, [term()]} | {:error, term()}
  defp reverse_declarations({:ok, declarations}), do: {:ok, Enum.reverse(declarations)}
  defp reverse_declarations({:error, _reason} = error), do: error

  @spec validate_declaration(term(), MapSet.t(module())) ::
          {:ok, {module(), [family()], integer()}} | {:error, term()}
  defp validate_declaration({callback, families, opts}, owned_modules)
       when is_atom(callback) and is_list(families) and is_list(opts) do
    if Keyword.keyword?(opts) do
      priority = Keyword.get(opts, :priority, 100)

      with :ok <- validate_families(families),
           :ok <- validate_priority(priority),
           :ok <- validate_callback(callback),
           :ok <- validate_ownership(callback, owned_modules) do
        {:ok, {callback, families, priority}}
      end
    else
      {:error, {:invalid_editor_event_handler, {callback, families, opts}}}
    end
  end

  defp validate_declaration(declaration, _owned_modules) do
    {:error, {:invalid_editor_event_handler, declaration}}
  end

  @spec validate_families([term()]) :: :ok | {:error, term()}
  defp validate_families([]), do: {:error, :callback_families_required}

  defp validate_families(families) do
    case Enum.reject(families, &(&1 in @supported_families)) do
      [] -> :ok
      invalid -> {:error, {:invalid_callback_families, invalid}}
    end
  end

  @spec validate_priority(term()) :: :ok | {:error, term()}
  defp validate_priority(priority) when is_integer(priority), do: :ok
  defp validate_priority(priority), do: {:error, {:invalid_priority, priority}}

  @spec validate_callback(module()) :: :ok | {:error, term()}
  defp validate_callback(callback) do
    with true <- Code.ensure_loaded?(callback),
         true <- function_exported?(callback, :handle_editor_event, 2) do
      :ok
    else
      false -> {:error, {:invalid_editor_event_callback, callback}}
    end
  end

  @spec validate_ownership(module(), MapSet.t(module())) :: :ok | {:error, term()}
  defp validate_ownership(callback, owned_modules) do
    if MapSet.member?(owned_modules, callback) do
      :ok
    else
      {:error, {:callback_module_not_owned, callback}}
    end
  end

  @spec put_callback(registry(), source(), family(), module(), integer()) :: true
  defp put_callback(table, source, family, callback, priority) do
    :ets.match_delete(table, {{family, :_, source, callback}, source, callback})
    key = {family, -priority, source, callback}
    :ets.insert(table, {key, source, callback})
  end

  @spec callback_entries(registry(), family()) :: [callback()]
  defp callback_entries(table, family) do
    table
    |> :ets.match_object({{family, :_, :_, :_}, :_, :_})
    |> Enum.map(fn {_key, source, callback} -> {source, callback} end)
  end

  @spec call_registry(registry(), term()) :: term()
  defp call_registry(registry, message) do
    case Process.whereis(registry) do
      nil -> {:error, :registry_not_started}
      _pid -> GenServer.call(registry, message)
    end
  end
end
