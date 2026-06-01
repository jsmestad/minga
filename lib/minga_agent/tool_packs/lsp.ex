defmodule MingaAgent.ToolPacks.LSP do
  @moduledoc """
  Bundled source-owned pack for LSP-backed agent tools.

  The pack contributes LSP query and mutation tools to the source-owned registry while leaving LSP process ownership in the existing core services. Safety-critical approval and execution still flow through `MingaAgent.Tool.Executor` and `MingaAgent.Tool.Context`.
  """

  use GenServer

  alias MingaAgent.Tool.BundledSources
  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec
  alias ReqLLM.Tool

  @read_only_names ~w(diagnostics definition references hover document_symbols workspace_symbols)
  @mutating_names ~w(rename code_actions)

  @typedoc "Bundled LSP tool pack source."
  @type source :: {:bundle, :lsp_tools}

  @doc "Returns the source used for all bundled LSP contributions."
  @spec source() :: source()
  def source, do: BundledSources.lsp_source()

  @doc "Returns the stable tool names contributed by this pack."
  @spec tool_names() :: [String.t()]
  def tool_names, do: BundledSources.lsp_tool_names()

  @doc "Starts the bundled LSP pack registrar."
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

  @impl true
  @spec init(keyword()) :: {:ok, atom()}
  def init(opts) do
    registry = Keyword.get(opts, :registry, Registry)
    :ok = register(registry)
    {:ok, registry}
  end

  @doc "Returns source-owned specs for every bundled LSP tool."
  @spec specs() :: [Spec.t()]
  def specs do
    tool_names()
    |> Enum.map(&spec_for!/1)
  end

  @doc "Registers all bundled LSP specs into a registry table or service."
  @spec register(atom()) :: :ok | {:error, term()}
  def register(table \\ Registry) when is_atom(table) do
    Enum.reduce_while(specs(), :ok, fn spec, :ok ->
      case Registry.register(table, spec) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec spec_for!(String.t()) :: Spec.t()
  defp spec_for!(name) do
    tool = tool_for!(name, MingaAgent.Tools.all(project_root: "."))

    Spec.new!(
      source: source(),
      name: tool.name,
      description: tool.description,
      parameter_schema: tool.parameter_schema,
      category: :lsp,
      approval_level: approval_for(tool.name),
      capabilities: capabilities_for(tool.name),
      context_requirements: [:tool_context],
      build: fn context -> callback_for(tool.name, context) end,
      metadata: metadata_for(tool.name)
    )
  end

  @spec callback_for(String.t(), ToolContext.t() | nil) :: Spec.callback()
  defp callback_for(name, nil) do
    name
    |> tool_for!(MingaAgent.Tools.all(project_root: "."))
    |> Map.fetch!(:callback)
  end

  defp callback_for(name, %ToolContext{} = context) do
    name
    |> tool_for!(MingaAgent.Tools.all(ToolContext.tools_opts(context)))
    |> Map.fetch!(:callback)
  end

  @spec tool_for!(String.t(), [Tool.t()]) :: Tool.t()
  defp tool_for!(name, tools) do
    Enum.find(tools, &(&1.name == name)) ||
      raise ArgumentError, "unknown LSP pack tool: #{name}"
  end

  @spec approval_for(String.t()) :: Spec.approval_level()
  defp approval_for(name) when name in @mutating_names, do: :ask
  defp approval_for(name) when name in @read_only_names, do: :auto

  @spec capabilities_for(String.t()) :: [Spec.capability()]
  defp capabilities_for("code_actions"), do: [:lsp_read, :lsp_mutate]
  defp capabilities_for(name) when name in @mutating_names, do: [:lsp_mutate]
  defp capabilities_for(name) when name in @read_only_names, do: [:lsp_read]

  @spec metadata_for(String.t()) :: map()
  defp metadata_for("code_actions"), do: %{pack: :lsp_tools, destructive: :conditional}
  defp metadata_for(name) when name in @mutating_names, do: %{pack: :lsp_tools, destructive: true}
  defp metadata_for(_name), do: %{pack: :lsp_tools, destructive: false}
end
