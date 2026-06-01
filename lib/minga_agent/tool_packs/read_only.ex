defmodule MingaAgent.ToolPacks.ReadOnly do
  @moduledoc """
  Bundled source-owned pack for low-risk read-only agent tools.

  The pack keeps the long-standing tool names, schemas, descriptions, and callbacks while letting the registry treat these tools as one reloadable bundled source. That gives extension disable/reload tests a real pack boundary before higher-risk mutating tools move out of the monolithic list.
  """

  use GenServer

  alias MingaAgent.Tool.BundledSources
  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec
  alias ReqLLM.Tool

  @typedoc "Bundled read-only tool pack source."
  @type source :: {:bundle, :read_only_tools}

  @doc "Returns the source used for all read-only pack contributions."
  @spec source() :: source()
  def source, do: BundledSources.read_only_source()

  @doc "Returns the stable tool names contributed by this pack."
  @spec tool_names() :: [String.t()]
  def tool_names, do: BundledSources.read_only_tool_names()

  @doc "Starts the bundled pack registrar."
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

  @doc "Returns source-owned specs for every tool in the bundled pack."
  @spec specs() :: [Spec.t()]
  def specs do
    tool_names()
    |> Enum.map(&spec_for!/1)
  end

  @doc "Registers all read-only pack specs into a registry table or service."
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
      category: category_for(tool.name),
      approval_level: :auto,
      capabilities: capabilities_for(tool.name),
      context_requirements: context_requirements_for(tool.name),
      build: fn context -> callback_for(tool.name, context) end,
      metadata: %{pack: :read_only_tools}
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
      raise ArgumentError, "unknown read-only pack tool: #{name}"
  end

  @spec category_for(String.t()) :: Spec.category()
  defp category_for("fetch_url"), do: :network
  defp category_for(_name), do: :filesystem

  @spec capabilities_for(String.t()) :: [Spec.capability()]
  defp capabilities_for("fetch_url"), do: [:network]
  defp capabilities_for(_name), do: [:read_project]

  @spec context_requirements_for(String.t()) :: [Spec.context_requirement()]
  defp context_requirements_for("fetch_url"), do: []
  defp context_requirements_for(_name), do: [:tool_context]
end
