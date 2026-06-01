defmodule MingaAgent.Tool.Registry do
  @moduledoc """
  ETS-backed source-owned registry for agent tool specifications.

  The registry stores declarative `MingaAgent.Tool.Spec` structs. Executable callbacks are built later from a per-session `MingaAgent.Tool.Context`, so registry startup does not close over a process cwd or session state.
  """

  use GenServer

  alias MingaAgent.Tool.Spec

  @table __MODULE__

  @typedoc "Tool contribution source."
  @type source :: Spec.source()

  @typedoc "Registration failure reason."
  @type register_error ::
          {:reserved_builtin_tool, String.t(), source()}
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

  @doc false
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
      unregister_source_direct(table, source)
    end
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Looks up a tool spec by name."
  @spec lookup(String.t()) :: {:ok, Spec.t()} | :error
  def lookup(name) when is_binary(name), do: lookup(@table, name)

  @doc false
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

  @doc false
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

  @doc false
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
    {:reply, unregister_source_direct(table, source), table}
  end

  @doc "Converts a `ReqLLM.Tool` struct to a config-owned `MingaAgent.Tool.Spec`."
  @spec from_req_tool(ReqLLM.Tool.t()) :: Spec.t()
  def from_req_tool(%ReqLLM.Tool{} = tool) do
    Spec.new!(
      source: :config,
      name: tool.name,
      description: tool.description || "",
      parameter_schema: tool.parameter_schema || %{},
      callback: tool.callback,
      category: categorize(tool.name),
      approval_level: approval_for(tool.name),
      capabilities: capabilities_for(tool.name),
      context_requirements: context_requirements_for(tool.name)
    )
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

      {:ok, %Spec{source: :builtin}} ->
        {:error, {:reserved_builtin_tool, name, attempted_source}}

      {:ok, %Spec{source: existing_source}} ->
        {:error, {:duplicate_tool_name, name, existing_source, attempted_source}}

      :error ->
        if built_in_name?(name) and attempted_source != :builtin do
          {:error, {:reserved_builtin_tool, name, attempted_source}}
        else
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

  @spec maybe_register_cleanup_callback(atom()) :: :ok
  defp maybe_register_cleanup_callback(@table) do
    Minga.Extension.ContributionCleanup.register(
      :agent_tool_registry,
      &__MODULE__.unregister_source/1
    )
  end

  defp maybe_register_cleanup_callback(_table), do: :ok

  @spec built_in_name?(String.t()) :: boolean()
  defp built_in_name?(name), do: name in MingaAgent.Tools.builtin_names()

  @spec categorize(String.t()) :: Spec.category()
  defp categorize("read_file"), do: :filesystem
  defp categorize("write_file"), do: :filesystem
  defp categorize("edit_file"), do: :filesystem
  defp categorize("multi_edit_file"), do: :filesystem
  defp categorize("apply_diff"), do: :filesystem
  defp categorize("list_directory"), do: :filesystem
  defp categorize("find"), do: :filesystem
  defp categorize("grep"), do: :filesystem
  defp categorize("shell"), do: :shell
  defp categorize("fetch_url"), do: :network
  defp categorize("subagent"), do: :agent
  defp categorize("describe_runtime"), do: :agent
  defp categorize("describe_tools"), do: :agent
  defp categorize("git_status"), do: :git
  defp categorize("git_diff"), do: :git
  defp categorize("git_log"), do: :git
  defp categorize("git_stage"), do: :git
  defp categorize("git_commit"), do: :git
  defp categorize("memory_write"), do: :memory
  defp categorize("diagnostics"), do: :lsp
  defp categorize("definition"), do: :lsp
  defp categorize("references"), do: :lsp
  defp categorize("hover"), do: :lsp
  defp categorize("document_symbols"), do: :lsp
  defp categorize("workspace_symbols"), do: :lsp
  defp categorize("rename"), do: :lsp
  defp categorize("code_actions"), do: :lsp
  defp categorize(_), do: :custom

  @spec approval_for(String.t()) :: Spec.approval_level()
  defp approval_for(name) do
    if MingaAgent.Tools.destructive?(name), do: :ask, else: :auto
  end

  @spec capabilities_for(String.t()) :: [Spec.capability()]
  defp capabilities_for(name)
       when name in ["write_file", "edit_file", "multi_edit_file", "apply_diff", "delete_file"],
       do: [:mutate_project]

  defp capabilities_for(name) when name in ["read_file", "list_directory", "find", "grep"],
    do: [:read_project]

  defp capabilities_for("shell"), do: [:run_shell]
  defp capabilities_for(name) when name in ["git_stage", "git_commit"], do: [:git_mutate]
  defp capabilities_for(name) when name in ["git_status", "git_diff", "git_log"], do: [:git_read]
  defp capabilities_for("fetch_url"), do: [:network]
  defp capabilities_for("memory_write"), do: [:memory_write]
  defp capabilities_for("subagent"), do: [:spawn_agent]
  defp capabilities_for(name) when name in ["rename", "code_actions"], do: [:lsp_mutate]

  defp capabilities_for(name)
       when name in [
              "diagnostics",
              "definition",
              "references",
              "hover",
              "document_symbols",
              "workspace_symbols"
            ],
       do: [:lsp_read]

  defp capabilities_for(_name), do: []

  @spec context_requirements_for(String.t()) :: [Spec.context_requirement()]
  defp context_requirements_for(name)
       when name in [
              "read_file",
              "write_file",
              "edit_file",
              "multi_edit_file",
              "apply_diff",
              "delete_file",
              "list_directory",
              "find",
              "grep",
              "shell",
              "subagent",
              "git_status",
              "git_diff",
              "git_log",
              "git_stage",
              "git_commit",
              "memory_write",
              "diagnostics",
              "definition",
              "references",
              "hover",
              "document_symbols",
              "workspace_symbols",
              "rename",
              "code_actions"
            ],
       do: [:tool_context]

  defp context_requirements_for(_name), do: []
end
