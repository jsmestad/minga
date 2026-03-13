defmodule Minga.Agent.ProviderResolver do
  @moduledoc """
  Resolves which agent provider module to use based on configuration.

  The `:agent_provider` config option controls selection:

  - `:auto` (default) — checks for native API credentials first, then falls
    back to pi RPC if `pi` is on `$PATH`, then native with an auth prompt
  - `:native` — always uses the native ReqLLM provider
  - `:pi_rpc` — always uses the pi RPC provider

  This module is called by the Session during init and by any code that
  starts a new agent session.
  """

  alias Minga.Agent.Credentials
  alias Minga.Config.Options, as: ConfigOptions

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

  Returns a map with `:module` (the provider module to start) and `:name`
  (a human-readable label for status messages).
  """
  @spec resolve() :: resolved()
  def resolve do
    preference = read_config_provider()
    resolve(preference)
  end

  @doc """
  Resolves a specific provider preference to a module.
  """
  @spec resolve(:auto | :native | :pi_rpc) :: resolved()
  def resolve(:native) do
    %Resolved{module: Minga.Agent.Providers.Native, name: "native"}
  end

  def resolve(:pi_rpc) do
    %Resolved{module: Minga.Agent.Providers.PiRpc, name: "pi_rpc"}
  end

  def resolve(:auto) do
    resolve_auto()
  end

  # Auto resolution priority:
  # 1. Native provider if any API credentials are configured (env or file)
  # 2. Pi RPC if `pi` binary is on $PATH
  # 3. Native provider with no credentials (will prompt user to authenticate)
  @spec resolve_auto() :: resolved()
  defp resolve_auto do
    resolve_auto(has_native_credentials?(), pi_available?())
  end

  @spec resolve_auto(boolean(), boolean()) :: resolved()
  defp resolve_auto(true, _pi_available) do
    %Resolved{module: Minga.Agent.Providers.Native, name: "native (auto)"}
  end

  defp resolve_auto(false, true) do
    %Resolved{module: Minga.Agent.Providers.PiRpc, name: "pi_rpc (auto, no API keys)"}
  end

  defp resolve_auto(false, false) do
    %Resolved{module: Minga.Agent.Providers.Native, name: "native (auto, no credentials)"}
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
  rescue
    ArgumentError -> false
  catch
    :exit, _ -> false
  end

  @spec pi_available?() :: boolean()
  defp pi_available? do
    System.find_executable("pi") != nil
  end

  @spec read_config_provider() :: :auto | :native | :pi_rpc
  defp read_config_provider do
    ConfigOptions.get(:agent_provider)
  rescue
    # ConfigOptions agent may not be running (e.g. in tests)
    ArgumentError -> :auto
  catch
    :exit, _ -> :auto
  end

  @spec read_config_model() :: String.t() | nil
  defp read_config_model do
    ConfigOptions.get(:agent_model)
  rescue
    ArgumentError -> nil
  catch
    :exit, _ -> nil
  end
end
