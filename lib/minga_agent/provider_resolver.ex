defmodule MingaAgent.ProviderResolver do
  @moduledoc """
  Resolves which agent provider module to use based on configuration.

  Provider declarations live in `MingaAgent.ProviderRegistry`. The resolver preserves the existing `:auto` and `:native` behavior while also accepting registered string provider ids for future provider packs.
  """

  alias Minga.Config
  alias MingaAgent.ProviderRegistry

  defmodule Resolved do
    @moduledoc false
    @enforce_keys [:id, :source, :module, :name, :display_name]
    defstruct [:id, :source, :module, :name, :display_name, :spec]

    @type t :: %__MODULE__{
            id: String.t(),
            source: Minga.Extension.ContributionCleanup.contribution_source(),
            module: module(),
            name: String.t(),
            display_name: String.t(),
            spec: MingaAgent.Provider.Spec.t() | nil
          }
  end

  @typedoc "Resolved provider information."
  @type resolved :: Resolved.t()

  @typedoc "Provider preference accepted by config and callers."
  @type preference :: :auto | :native | String.t()

  @doc """
  Resolves the provider module based on the current config.

  The application `:test_provider_module` override keeps top precedence so tests can avoid mutating the daemon provider registry.
  """
  @spec resolve() :: resolved()
  def resolve do
    case Application.get_env(:minga, :test_provider_module) do
      nil -> resolve(read_config_provider())
      module when is_atom(module) -> test_resolution(module)
    end
  end

  @doc "Resolves a specific provider preference."
  @spec resolve(preference()) :: resolved()
  @spec resolve(preference(), keyword()) :: resolved()
  def resolve(preference, opts \\ [])

  def resolve(:auto, opts) do
    registry = Keyword.get(opts, :registry, ProviderRegistry)
    registry_resolution(registry, "native", "native (auto)")
  end

  def resolve(:native, opts) do
    registry = Keyword.get(opts, :registry, ProviderRegistry)
    registry_resolution(registry, "native", "native")
  end

  def resolve(provider_id, opts) when is_binary(provider_id) do
    registry = Keyword.get(opts, :registry, ProviderRegistry)
    registry_resolution(registry, provider_id, provider_id)
  end

  @doc "Returns the configured model string, or nil to use the provider's default."
  @spec configured_model() :: String.t() | nil
  def configured_model do
    read_config_model()
  end

  @spec registry_resolution(GenServer.server(), String.t(), String.t()) :: resolved()
  defp registry_resolution(registry, id, name) do
    case ProviderRegistry.lookup(registry, id) do
      {:ok, %{spec: spec}} ->
        %Resolved{
          id: spec.id,
          source: spec.source,
          module: spec.module,
          name: name,
          display_name: spec.display_name,
          spec: spec
        }

      {:error, reason} ->
        raise ArgumentError, "agent provider #{inspect(id)} is not available: #{inspect(reason)}"
    end
  catch
    :exit, reason ->
      raise ArgumentError, "agent provider registry unavailable: #{inspect(reason)}"
  end

  @spec test_resolution(module()) :: resolved()
  defp test_resolution(module) do
    %Resolved{
      id: "test",
      source: :config,
      module: module,
      name: "test",
      display_name: "test",
      spec: nil
    }
  end

  @spec read_config_provider() :: preference()
  defp read_config_provider do
    Config.get(:agent_provider)
  end

  @spec read_config_model() :: String.t() | nil
  defp read_config_model do
    Config.get(:agent_model)
  end
end
