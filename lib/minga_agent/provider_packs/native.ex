defmodule MingaAgent.ProviderPacks.Native do
  @moduledoc """
  Bundled source-owned provider pack for the native ReqLLM-backed provider.

  The pack keeps the existing `native` provider id, model prefixes, capabilities, credential requirements, and implementation module while registering that declaration through the provider registry as a bundled source. Session code still owns credentials, retries, streaming events, costs, compaction, and provider lifecycle.
  """

  use GenServer

  alias MingaAgent.Provider.Spec
  alias MingaAgent.ProviderRegistry
  alias MingaAgent.Providers.Native

  @typedoc "Bundled native provider source."
  @type source :: {:bundle, :native_provider}

  @doc "Returns the source used for native provider contributions."
  @spec source() :: source()
  def source, do: {:bundle, :native_provider}

  @doc "Starts the bundled native provider pack registrar."
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
  @spec init(keyword()) :: {:ok, GenServer.server()} | {:stop, term()}
  def init(opts) do
    registry = Keyword.get(opts, :registry, ProviderRegistry)

    case register(registry) do
      :ok -> {:ok, registry}
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc "Returns the bundled native provider spec."
  @spec spec() :: Spec.t()
  def spec do
    Spec.new!(
      source: source(),
      id: "native",
      module: Native,
      display_name: "native",
      model_prefixes: ["anthropic:", "openai:", "ollama:", "groq:", "bedrock:"],
      capabilities: [:streaming, :tools, :mcp, :thinking, :model_switching],
      credential_requirements: [:llm]
    )
  end

  @doc "Registers the native provider spec into a registry."
  @spec register(GenServer.server()) :: :ok | {:error, term()}
  def register(registry \\ ProviderRegistry) do
    ProviderRegistry.register(registry, spec())
  end
end
