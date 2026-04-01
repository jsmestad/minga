defmodule MingaAgent.Tool.Registry do
  @moduledoc """
  ETS-backed registry for agent tool specifications.

  Stores `MingaAgent.Tool.Spec` structs in an ETS table with
  `read_concurrency: true` for zero-contention lookups in the hot
  tool-execution path. Writes happen only at startup (built-in tool
  registration) and when extensions register custom tools.

  ## Built-in registration

  On startup, all tools from `MingaAgent.Tools.all/1` are converted to
  `Spec` structs and registered. The Registry becomes the single source
  of truth for tool discovery and lookup.

  ## Usage

      MingaAgent.Tool.Registry.lookup("read_file")
      #=> {:ok, %MingaAgent.Tool.Spec{name: "read_file", ...}}

      MingaAgent.Tool.Registry.registered?("shell")
      #=> true

      MingaAgent.Tool.Registry.all()
      #=> [%MingaAgent.Tool.Spec{}, ...]
  """

  use GenServer

  alias MingaAgent.Tool.Spec

  @table __MODULE__

  # ── Lifecycle ───────────────────────────────────────────────────────────────

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
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Registers a tool spec in the registry.

  Overwrites any existing spec with the same name. Returns `:ok`.
  """
  @spec register(Spec.t()) :: :ok
  def register(%Spec{} = spec), do: register(@table, spec)

  @doc false
  @spec register(atom(), Spec.t()) :: :ok
  def register(table, %Spec{name: name} = spec) when is_atom(table) do
    :ets.insert(table, {name, spec})
    :ok
  end

  @doc """
  Looks up a tool spec by name.

  Returns `{:ok, spec}` if found, `:error` otherwise.
  """
  @spec lookup(String.t()) :: {:ok, Spec.t()} | :error
  def lookup(name) when is_binary(name), do: lookup(@table, name)

  @doc false
  @spec lookup(atom(), String.t()) :: {:ok, Spec.t()} | :error
  def lookup(table, name) when is_atom(table) and is_binary(name) do
    case :ets.lookup(table, name) do
      [{^name, spec}] -> {:ok, spec}
      [] -> :error
    end
  end

  @doc """
  Returns all registered tool specs.
  """
  @spec all() :: [Spec.t()]
  def all, do: all(@table)

  @doc false
  @spec all(atom()) :: [Spec.t()]
  def all(table) when is_atom(table) do
    :ets.tab2list(table)
    |> Enum.map(fn {_name, spec} -> spec end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Returns true if a tool with the given name is registered.
  """
  @spec registered?(String.t()) :: boolean()
  def registered?(name) when is_binary(name), do: registered?(@table, name)

  @doc false
  @spec registered?(atom(), String.t()) :: boolean()
  def registered?(table, name) when is_atom(table) and is_binary(name) do
    :ets.member(table, name)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, atom()}
  def init(opts) do
    table = Keyword.get(opts, :name, __MODULE__)

    :ets.new(table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    register_builtins(table, opts)

    {:ok, table}
  end

  # ── Built-in registration ──────────────────────────────────────────────────

  @spec register_builtins(atom(), keyword()) :: :ok
  defp register_builtins(table, opts) do
    project_root = Keyword.get(opts, :project_root, default_project_root())
    tools = MingaAgent.Tools.all(project_root: project_root)

    Enum.each(tools, fn req_tool ->
      spec = from_req_tool(req_tool)
      register(table, spec)
    end)
  end

  @spec default_project_root() :: String.t()
  defp default_project_root do
    File.cwd!()
  rescue
    _ -> "."
  end

  @doc """
  Converts a `ReqLLM.Tool` struct to a `MingaAgent.Tool.Spec`.

  Maps the tool name to a category and approval level based on the
  tool's characteristics.
  """
  @spec from_req_tool(ReqLLM.Tool.t()) :: Spec.t()
  def from_req_tool(%ReqLLM.Tool{} = tool) do
    name = tool.name
    category = categorize(name)
    approval_level = approval_for(name)

    Spec.new!(
      name: name,
      description: tool.description || "",
      parameter_schema: tool.parameter_schema || %{},
      callback: tool.callback,
      category: category,
      approval_level: approval_level
    )
  end

  @spec categorize(String.t()) :: Spec.category()
  defp categorize("read_file"), do: :filesystem
  defp categorize("write_file"), do: :filesystem
  defp categorize("edit_file"), do: :filesystem
  defp categorize("multi_edit_file"), do: :filesystem
  defp categorize("list_directory"), do: :filesystem
  defp categorize("find"), do: :filesystem
  defp categorize("grep"), do: :filesystem
  defp categorize("shell"), do: :shell
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
    if MingaAgent.Tools.destructive?(name) do
      :ask
    else
      :auto
    end
  end
end
