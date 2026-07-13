defmodule MingaAgent.ToolPacks.ReadOnly do
  @moduledoc """
  Bundled source-owned pack for low-risk read-only agent tools.

  The pack keeps the long-standing tool names, schemas, descriptions, and callbacks while letting the registry treat these tools as one reloadable bundled source. That gives extension disable/reload tests a real pack boundary before higher-risk mutating tools move out of the monolithic list.
  """

  use GenServer

  alias MingaAgent.Tool.BundledSources
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

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
  @spec init(keyword()) :: {:ok, atom()} | {:stop, term()}
  def init(opts) do
    registry = Keyword.get(opts, :registry, Registry)

    case register(registry) do
      :ok -> {:ok, registry}
      {:error, reason} -> {:stop, {:read_only_tool_pack_registration_failed, registry, reason}}
    end
  end

  @doc "Returns source-owned specs for every tool in the bundled pack."
  @spec specs() :: [Spec.t()]
  def specs do
    MingaAgent.Tools.specs()
    |> Enum.filter(&(&1.source == source()))
  end

  @doc "Registers all read-only pack specs into a registry table or service."
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
    Enum.each(previous_specs, fn spec -> :ok = Registry.register(table, spec) end)
    :ok
  end
end
