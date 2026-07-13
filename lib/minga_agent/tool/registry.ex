defmodule MingaAgent.Tool.Registry do
  @moduledoc """
  ETS-backed source-owned registry for agent tool specifications.

  The registry stores declarative `MingaAgent.Tool.Spec` structs. Executable callbacks are built later from a per-session `MingaAgent.Tool.Context`, so registry startup does not close over a process cwd or session state.
  """

  use GenServer

  alias MingaAgent.Tool.BundledSources
  alias MingaAgent.Tool.Spec

  @table __MODULE__

  @typedoc "Tool contribution source."
  @type source :: Spec.source()

  @typedoc "Registration failure reason."
  @type register_error ::
          {:reserved_tool_name, String.t(), owner_source :: source(),
           attempted_source :: source()}
          | {:duplicate_tool_name, String.t(), existing_source :: source(),
             attempted_source :: source()}
          | {:invalid_spec, term()}

  @doc "Starts the registry GenServer that owns the ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
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

  @doc "Registers a tool spec in the registry. Same-source registrations replace existing entries."
  @spec register(Spec.t() | keyword() | map()) :: :ok | {:error, register_error()}
  def register(spec), do: register(@table, spec)

  @spec register(atom(), Spec.t() | keyword() | map()) :: :ok | {:error, register_error()}
  def register(table, %Spec{} = spec) when is_atom(table) do
    register_validated(table, Map.from_struct(spec))
  end

  def register(table, attrs) when is_atom(table) and (is_list(attrs) or is_map(attrs)) do
    register_validated(table, attrs)
  end

  @doc "Removes every tool contributed by a source."
  @spec unregister_source(source()) :: :ok
  @spec unregister_source(atom(), source()) :: :ok
  def unregister_source(source), do: unregister_source(@table, source)

  def unregister_source(table, source) when is_atom(table) do
    if registry_process?(table) do
      GenServer.call(table, {:unregister_source, source})
    else
      result = unregister_source_direct(table, source)
      emit_direct_change(table, source)
      result
    end
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Looks up a tool spec by name."
  @spec lookup(String.t()) :: {:ok, Spec.t()} | :error
  def lookup(name) when is_binary(name), do: lookup(@table, name)

  @spec lookup(atom(), String.t()) :: {:ok, Spec.t()} | :error
  def lookup(table, name) when is_atom(table) and is_binary(name) do
    case :ets.lookup(table, name) do
      [{^name, spec}] -> {:ok, spec}
      [] -> :error
    end
  catch
    :error, :badarg -> :error
  end

  @doc "Returns all registered tool specs."
  @spec all() :: [Spec.t()]
  def all, do: all(@table)

  @spec all(atom()) :: [Spec.t()]
  def all(table) when is_atom(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, spec} -> spec end)
    |> Enum.sort_by(& &1.name)
  catch
    :error, :badarg -> []
  end

  @doc "Returns true if a tool with the given name is registered."
  @spec registered?(String.t()) :: boolean()
  def registered?(name) when is_binary(name), do: registered?(@table, name)

  @spec registered?(atom(), String.t()) :: boolean()
  def registered?(table, name) when is_atom(table) and is_binary(name) do
    :ets.member(table, name)
  catch
    :error, :badarg -> false
  end

  @impl true
  @spec init(keyword()) :: {:ok, atom()}
  def init(opts) do
    table = Keyword.get(opts, :name, __MODULE__)

    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])
    maybe_register_cleanup_callback(table)
    register_builtins(table)

    {:ok, table}
  end

  @impl true
  def handle_call({:register, %Spec{} = spec}, _from, table) do
    {:reply, register_spec(table, spec), table}
  end

  def handle_call({:unregister_source, source}, _from, table) do
    result = unregister_source_direct(table, source)
    emit_change(table, source)
    {:reply, result, table}
  end

  @doc "Converts a `ReqLLM.Tool` struct to a config-owned `MingaAgent.Tool.Spec`."
  @spec from_req_tool(ReqLLM.Tool.t()) :: Spec.t()
  def from_req_tool(%ReqLLM.Tool{} = tool) do
    metadata = canonical_metadata(tool.name)

    Spec.new!(
      source: :config,
      name: tool.name,
      description: tool.description || "",
      parameter_schema: tool.parameter_schema || %{},
      callback: tool.callback,
      category: metadata.category,
      approval_level: metadata.approval_level,
      capabilities: metadata.capabilities,
      context_requirements: metadata.context_requirements
    )
  end

  @spec canonical_metadata(String.t()) :: map()
  defp canonical_metadata(name) do
    case Enum.find(MingaAgent.Tools.specs(), &(&1.name == name)) do
      %Spec{} = spec ->
        Map.take(spec, [:category, :approval_level, :capabilities, :context_requirements])

      nil ->
        %{category: :custom, approval_level: :auto, capabilities: [], context_requirements: []}
    end
  end

  @spec register_validated(atom(), Spec.t() | keyword() | map()) ::
          :ok | {:error, register_error()}
  defp register_validated(table, attrs) do
    case Spec.new(attrs) do
      {:ok, spec} -> register_validated_spec(table, spec)
      {:error, reason} -> {:error, {:invalid_spec, reason}}
    end
  end

  @spec register_validated_spec(atom(), Spec.t()) :: :ok | {:error, register_error()}
  defp register_validated_spec(table, %Spec{} = spec) do
    if registry_process?(table) do
      GenServer.call(table, {:register, spec})
    else
      register_spec(table, spec)
    end
  end

  @spec registry_process?(atom()) :: boolean()
  defp registry_process?(table) do
    case Process.whereis(table) do
      nil -> false
      pid -> pid != self()
    end
  end

  @spec unregister_source_direct(atom(), source()) :: :ok
  defp unregister_source_direct(table, source) do
    table
    |> all()
    |> Enum.filter(&(&1.source == source))
    |> Enum.each(fn spec -> :ets.delete(table, spec.name) end)

    :ok
  catch
    :error, :badarg -> :ok
  end

  @spec register_spec(atom(), Spec.t()) :: :ok | {:error, register_error()}
  defp register_spec(table, %Spec{} = spec) do
    case registration_allowed?(table, spec) do
      :ok ->
        :ets.insert(table, {spec.name, spec})
        emit_direct_change(table, spec.source)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @spec registration_allowed?(atom(), Spec.t()) :: :ok | {:error, register_error()}
  defp registration_allowed?(table, %Spec{source: attempted_source, name: name}) do
    case lookup(table, name) do
      {:ok, %Spec{source: existing_source}} when existing_source == attempted_source ->
        :ok

      {:ok, %Spec{source: existing_source}} ->
        existing_source_registration(existing_source, name, attempted_source)

      :error ->
        case reserved_owner_for(name) do
          {:ok, ^attempted_source} ->
            :ok

          {:ok, owner_source} ->
            {:error, {:reserved_tool_name, name, owner_source, attempted_source}}

          :error ->
            :ok
        end
    end
  end

  @spec register_builtins(atom()) :: :ok
  defp register_builtins(table) do
    Enum.each(MingaAgent.Tools.builtin_specs(), fn spec ->
      :ok = register(table, spec)
    end)
  end

  @spec emit_direct_change(atom(), source()) :: :ok
  defp emit_direct_change(@table, source), do: emit_change(@table, source)
  defp emit_direct_change(_table, _source), do: :ok

  @spec emit_change(atom(), source()) :: :ok
  defp emit_change(@table, source) do
    Minga.Events.broadcast(:agent_tools_changed, %Minga.Events.AgentToolsChangedEvent{
      source: source
    })
  end

  defp emit_change(_table, _source), do: :ok

  @spec maybe_register_cleanup_callback(atom()) :: :ok
  defp maybe_register_cleanup_callback(@table) do
    Minga.Extension.ContributionCleanup.register(
      :agent_tool_registry,
      &__MODULE__.unregister_source/1
    )
  end

  defp maybe_register_cleanup_callback(_table), do: :ok

  @spec existing_source_registration(source(), String.t(), source()) ::
          :ok | {:error, register_error()}
  defp existing_source_registration(existing_source, name, attempted_source) do
    if protected_source?(existing_source) do
      {:error, {:reserved_tool_name, name, existing_source, attempted_source}}
    else
      {:error, {:duplicate_tool_name, name, existing_source, attempted_source}}
    end
  end

  @spec protected_source?(source()) :: boolean()
  defp protected_source?(:builtin), do: true
  defp protected_source?({:bundle, _name} = source), do: BundledSources.known_source?(source)
  defp protected_source?(_source), do: false

  @spec reserved_owner_for(String.t()) :: {:ok, source()} | :error
  defp reserved_owner_for(name) do
    if name in MingaAgent.Tools.builtin_names() do
      {:ok, :builtin}
    else
      BundledSources.reserved_source_for(name)
    end
  end
end
