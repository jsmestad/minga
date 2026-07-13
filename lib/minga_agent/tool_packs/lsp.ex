defmodule MingaAgent.ToolPacks.LSP do
  @moduledoc """
  Bundled source-owned pack for LSP-backed agent tools.

  The pack contributes LSP query and mutation tools to the source-owned registry while leaving LSP process ownership in the existing core services. Safety-critical approval and execution still flow through `MingaAgent.Tool.Executor` and `MingaAgent.Tool.Context`.
  """

  use GenServer

  alias MingaAgent.Tool.BundledSources
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

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
  @spec init(keyword()) :: {:ok, atom()} | {:stop, term()}
  def init(opts) do
    registry = Keyword.get(opts, :registry, Registry)

    case register(registry) do
      :ok -> {:ok, registry}
      {:error, reason} -> {:stop, {:lsp_tool_pack_registration_failed, registry, reason}}
    end
  end

  @doc "Returns source-owned specs for every bundled LSP tool."
  @spec specs() :: [Spec.t()]
  def specs do
    MingaAgent.Tools.specs()
    |> Enum.filter(&(&1.source == source()))
  end

  @doc "Registers all bundled LSP specs into a registry table or service."
  @spec register(atom()) :: :ok | {:error, term()}
  def register(table \\ Registry) when is_atom(table) do
    previous_specs = current_pack_name_specs(table)

    case register_specs(table, specs()) do
      :ok ->
        :ok

      {:error, reason} ->
        restore_pack_name_specs(table, previous_specs)
        {:error, reason}
    end
  end

  @spec register_specs(atom(), [Spec.t()]) :: :ok | {:error, term()}
  defp register_specs(table, specs) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      case Registry.register(table, spec) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec current_pack_name_specs(atom()) :: [Spec.t()]
  defp current_pack_name_specs(table) do
    tool_names()
    |> Enum.flat_map(fn name ->
      case Registry.lookup(table, name) do
        {:ok, spec} -> [spec]
        :error -> []
      end
    end)
  end

  @spec restore_pack_name_specs(atom(), [Spec.t()]) :: :ok
  defp restore_pack_name_specs(table, previous_specs) do
    Registry.unregister_source(table, source())
    Enum.each(previous_specs, fn spec -> restore_previous_spec(table, spec) end)
    :ok
  end

  @spec restore_previous_spec(atom(), Spec.t()) :: :ok
  defp restore_previous_spec(table, spec) do
    case Registry.register(table, spec) do
      :ok -> :ok
      {:error, _reason} -> restore_previous_spec_direct(table, spec)
    end
  end

  @spec restore_previous_spec_direct(atom(), Spec.t()) :: :ok
  defp restore_previous_spec_direct(table, spec) do
    :ets.insert(table, {spec.name, spec})
    :ok
  rescue
    ArgumentError -> :ok
  end
end
