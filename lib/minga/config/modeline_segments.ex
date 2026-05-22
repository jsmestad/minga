defmodule Minga.Config.ModelineSegments do
  @moduledoc """
  ETS-backed registry for custom modeline segments.

  User config and extensions register segment render functions here. The traditional shell modeline reads the registry on each render frame so config reloads take effect immediately without coupling the config layer to editor presentation modules.
  """

  use GenServer

  alias Minga.Config.ModelineSegment

  @table __MODULE__
  @warnings_table Module.concat(__MODULE__, Warnings)
  @reserved_names [
    :mode,
    :workspace,
    :filename,
    :git,
    :agent,
    :background_agent,
    :diagnostics,
    :parser,
    :lsp,
    :filetype,
    :position,
    :percent,
    :draft,
    :conflict,
    :merge_conflict,
    :selection
  ]

  @type table :: atom()
  @type source :: atom() | {:extension, atom()}
  @type register_error ::
          ModelineSegment.validation_error()
          | {:reserved_name, atom()}
          | {:duplicate_name, atom(), existing_source :: source(), attempted_source :: source()}

  @doc "Starts the process that owns the custom segment ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc "Returns built-in or otherwise reserved modeline segment names that custom segments cannot use."
  @spec reserved_names() :: [atom()]
  def reserved_names, do: @reserved_names

  @doc "Registers or replaces a custom modeline segment from user config."
  @spec register(atom(), keyword(), ModelineSegment.render_fun()) ::
          :ok | {:error, register_error()}
  def register(name, opts, render), do: register(@table, name, opts, render, :config)

  @doc "Registers or replaces a custom modeline segment for a source."
  @spec register(atom(), keyword(), ModelineSegment.render_fun(), source()) ::
          :ok | {:error, register_error()}
  def register(name, opts, render, source), do: register(@table, name, opts, render, source)

  @spec register(table(), atom(), keyword(), ModelineSegment.render_fun(), source()) ::
          :ok | {:error, register_error()}
  def register(table, name, opts, render, source)
      when is_atom(table) and is_atom(name) and is_list(opts) and is_function(render, 1) do
    case reserved_name?(name) do
      true ->
        {:error, {:reserved_name, name}}

      false ->
        case ModelineSegment.new(name, opts, render, source) do
          {:ok, segment} -> insert_segment(table, name, segment, source)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec reserved_name?(atom()) :: boolean()
  defp reserved_name?(name), do: name in @reserved_names

  @doc "Registers a custom modeline segment and raises on invalid declarations or collisions."
  @spec register!(atom(), keyword(), ModelineSegment.render_fun()) :: :ok
  def register!(name, opts, render) do
    case register(name, opts, render) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, register_error_message(name, reason)
    end
  end

  @spec insert_segment(table(), atom(), ModelineSegment.t(), source()) ::
          :ok | {:error, register_error()}
  defp insert_segment(table, name, segment, source) do
    with_writable_table(table, fn ->
      case lookup_existing(table, name) do
        %ModelineSegment{source: ^source} ->
          :ets.insert(table, {name, segment})
          :ok

        %ModelineSegment{source: existing_source} ->
          {:error, {:duplicate_name, name, existing_source, source}}

        nil ->
          :ets.insert(table, {name, segment})
          :ok
      end
    end)
  end

  @spec register_error_message(atom(), register_error()) :: String.t()
  def register_error_message(name, {:invalid_side, side}) do
    "Invalid modeline segment #{inspect(name)} side #{inspect(side)}. Expected :left or :right."
  end

  def register_error_message(name, {:invalid_priority, priority}) do
    "Invalid modeline segment #{inspect(name)} priority #{inspect(priority)}. Expected an integer."
  end

  def register_error_message(name, {:reserved_name, _segment_name}) do
    "Modeline segment #{inspect(name)} is reserved by a built-in segment and cannot be replaced."
  end

  def register_error_message(
        name,
        {:duplicate_name, _segment_name, existing_source, attempted_source}
      ) do
    "Modeline segment #{inspect(name)} is already registered by #{inspect(existing_source)} and cannot be replaced by #{inspect(attempted_source)}."
  end

  @doc "Unregisters one custom modeline segment."
  @spec unregister(atom()) :: :ok
  def unregister(name), do: unregister(@table, name)

  @spec unregister(table(), atom()) :: :ok
  def unregister(table, name) when is_atom(table) and is_atom(name) do
    with_writable_table(table, fn -> :ets.delete(table, name) end)
    :ok
  end

  @doc "Removes every segment owned by a source, such as one extension."
  @spec unregister_source(source()) :: :ok
  def unregister_source(source), do: unregister_source(@table, source)

  @spec unregister_source(table(), source()) :: :ok
  def unregister_source(table, source) when is_atom(table) do
    with_writable_table(table, fn -> unregister_source_entries(table, source) end)
    :ok
  end

  @spec unregister_source_entries(table(), source()) :: :ok
  defp unregister_source_entries(table, source) do
    table
    |> :ets.tab2list()
    |> Enum.each(&maybe_delete_source_segment(table, source, &1))

    :ok
  end

  @spec maybe_delete_source_segment(table(), source(), {atom(), ModelineSegment.t()}) :: :ok
  defp maybe_delete_source_segment(
         table,
         source,
         {name, %ModelineSegment{source: segment_source}}
       )
       when segment_source == source do
    :ets.delete(table, name)
    :ok
  end

  defp maybe_delete_source_segment(_table, _source, _entry), do: :ok

  @doc "Clears all custom modeline segments. Used during config reload."
  @spec reset() :: :ok
  def reset, do: reset(@table)

  @spec reset(table()) :: :ok
  def reset(table) when is_atom(table) do
    with_writable_table(table, fn -> :ets.delete_all_objects(table) end)
    reset_warnings(table)
    :ok
  end

  @doc "Clears warning-once modeline diagnostics without deleting registered segments."
  @spec reset_warnings() :: :ok
  def reset_warnings, do: reset_warnings(@table)

  @spec reset_warnings(table()) :: :ok
  def reset_warnings(table) when is_atom(table) do
    warnings_table = warnings_table(table)
    with_writable_table(warnings_table, fn -> :ets.delete_all_objects(warnings_table) end)
    :ok
  end

  @doc "Logs a warning once for a render-time modeline segment diagnostic."
  @spec warn_once(term(), String.t()) :: :ok
  def warn_once(key, message), do: warn_once(@table, key, message)

  @spec warn_once(table(), term(), String.t()) :: :ok
  def warn_once(table, key, message) when is_atom(table) and is_binary(message) do
    warnings_table = warnings_table(table)

    with_writable_table(warnings_table, fn ->
      case :ets.insert_new(warnings_table, {key, true}) do
        true -> Minga.Log.warning(:config, message)
        false -> :ok
      end
    end)
  end

  @doc "Looks up a custom segment by name."
  @spec lookup(atom()) :: ModelineSegment.t() | nil
  def lookup(name), do: lookup(@table, name)

  @spec lookup(table(), atom()) :: ModelineSegment.t() | nil
  def lookup(table, name) when is_atom(table) and is_atom(name) do
    case table_ready?(table) do
      true -> lookup_existing(table, name)
      false -> nil
    end
  end

  @doc "Returns all custom segment names declared for a side, ordered by priority descending then name."
  @spec names_for_side(ModelineSegment.side()) :: [atom()]
  def names_for_side(side), do: names_for_side(@table, side)

  @spec names_for_side(table(), ModelineSegment.side()) :: [atom()]
  def names_for_side(table, side) when is_atom(table) and side in [:left, :right] do
    table
    |> list()
    |> Enum.filter(&(&1.side == side))
    |> Enum.sort_by(&{-&1.priority, &1.name})
    |> Enum.map(& &1.name)
  end

  @doc "Returns all custom modeline segments."
  @spec list() :: [ModelineSegment.t()]
  def list, do: list(@table)

  @spec list(table()) :: [ModelineSegment.t()]
  def list(table) when is_atom(table) do
    case table_ready?(table) do
      true -> list_existing(table)
      false -> []
    end
  end

  @impl true
  @spec init(keyword()) :: {:ok, table()}
  def init(opts) do
    table = Keyword.get(opts, :name, @table)
    create_owned_table(table)
    create_owned_table(warnings_table(table))
    {:ok, table}
  end

  @spec lookup_existing(table(), atom()) :: ModelineSegment.t() | nil
  defp lookup_existing(table, name) do
    case :ets.lookup(table, name) do
      [{^name, %ModelineSegment{} = segment}] -> segment
      [] -> nil
    end
  end

  @spec list_existing(table()) :: [ModelineSegment.t()]
  defp list_existing(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, segment} -> segment end)
  end

  @spec with_writable_table(table(), (-> result)) :: result | :ok when result: term()
  defp with_writable_table(table, fun) do
    case ensure_writable_table(table) do
      :ok -> fun.()
      :missing -> :ok
    end
  end

  @spec ensure_writable_table(table()) :: :ok | :missing
  defp ensure_writable_table(@table) do
    case table_ready?(@table) do
      true -> :ok
      false -> :missing
    end
  end

  defp ensure_writable_table(table) do
    case table_ready?(table) do
      true -> :ok
      false -> create_owned_table(table)
    end
  end

  @spec table_ready?(table()) :: boolean()
  defp table_ready?(table), do: :ets.whereis(table) != :undefined

  @spec create_owned_table(table()) :: :ok
  defp create_owned_table(table) do
    delete_existing_table(table)
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  end

  @spec warnings_table(table()) :: table()
  defp warnings_table(@table), do: @warnings_table
  defp warnings_table(table), do: Module.concat(table, Warnings)

  @spec delete_existing_table(table()) :: :ok
  defp delete_existing_table(table) do
    case table_ready?(table) do
      true -> delete_existing_table!(table)
      false -> :ok
    end
  end

  @spec delete_existing_table!(table()) :: :ok
  defp delete_existing_table!(table) do
    :ets.delete(table)
    :ok
  rescue
    ArgumentError ->
      :ok
  end
end
