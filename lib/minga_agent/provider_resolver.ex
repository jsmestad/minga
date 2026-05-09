defmodule MingaAgent.ProviderResolver do
  @moduledoc """
  Resolves which agent provider module to use based on configuration.

  The `:agent_provider` config option controls selection:

  - `:auto` (default) - checks for native API credentials first, then starts
    the native provider with an onboarding message if no credentials exist
  - `:native` - always uses the native ReqLLM provider

  This module is called by the Session during init and by any code that
  starts a new agent session.
  """

  alias MingaAgent.Credentials
  alias Minga.Config

  defmodule Resolved do
    @moduledoc false
    @enforce_keys [:module, :name]
    defstruct [:module, :name]

    @type t :: %__MODULE__{
            module: module(),
            name: String.t()
          }
  end

  @typedoc "Resolved provider information."
  @type resolved :: Resolved.t()

  @doc """
  Resolves the provider module based on the current config.

  Returns a map with `:module` (the provider to start) and `:name`
  (a human-readable label for status messages).
  """
  @spec resolve() :: resolved()
  def resolve do
    # Allow tests to override the provider module via application env.
    # This avoids starting real providers in tests that exercise session
    # lifecycle without caring which provider backs it.
    case Application.get_env(:minga, :test_provider_module) do
      nil ->
        resolve(read_config_provider())

      module when is_atom(module) ->
        %Resolved{module: module, name: "test"}
    end
  end

  @doc """
  Resolves a specific provider preference to a module.
  """
  @spec resolve(:auto | :native) :: resolved()
  def resolve(:native) do
    %Resolved{module: MingaAgent.Providers.Native, name: "native"}
  end

  def resolve(:auto) do
    resolve_auto(has_native_credentials?())
  end

  # Auto resolution priority:
  # 1. Native provider if any API credentials are configured (env or file)
  # 2. Native provider with no credentials (will prompt user to authenticate)
  @spec resolve_auto(boolean()) :: resolved()
  defp resolve_auto(true) do
    %Resolved{module: MingaAgent.Providers.Native, name: "native (auto)"}
  end

  defp resolve_auto(false) do
    %Resolved{module: MingaAgent.Providers.Native, name: "native (auto, no credentials)"}
  end

  @doc """
  Returns the configured model string, or nil to use the provider's default.
  """
  @spec configured_model() :: String.t() | nil
  def configured_model do
    read_config_model()
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec has_native_credentials?() :: boolean()
  defp has_native_credentials? do
    Credentials.any_configured?()
  end

  @spec read_config_provider() :: :auto | :native
  defp read_config_provider do
    Config.get(:agent_provider)
  end

  @spec read_config_model() :: String.t() | nil
  defp read_config_model do
    Config.get(:agent_model)
  end
end
