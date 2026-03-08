defmodule Minga.Agent.ProviderResolver do
  @moduledoc """
  Resolves which agent provider module to use based on configuration.

  The `:agent_provider` config option controls selection:

  - `:auto` (default) — tries pi RPC first, falls back to native if `pi` is
    not on `$PATH`
  - `:native` — always uses the native ReqLLM provider
  - `:pi_rpc` — always uses the pi RPC provider

  This module is called by the Session during init and by any code that
  starts a new agent session.
  """

  alias Minga.Config.Options, as: ConfigOptions

  @typedoc "Resolved provider information."
  @type resolved :: %{
          module: module(),
          name: String.t()
        }

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
    %{module: Minga.Agent.Providers.Native, name: "native"}
  end

  def resolve(:pi_rpc) do
    %{module: Minga.Agent.Providers.PiRpc, name: "pi_rpc"}
  end

  def resolve(:auto) do
    if pi_available?() do
      %{module: Minga.Agent.Providers.PiRpc, name: "pi_rpc (auto)"}
    else
      %{module: Minga.Agent.Providers.Native, name: "native (auto, pi not found)"}
    end
  end

  @doc """
  Returns the configured model string, or nil to use the provider's default.
  """
  @spec configured_model() :: String.t() | nil
  def configured_model do
    read_config_model()
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec pi_available?() :: boolean()
  defp pi_available? do
    System.find_executable("pi") != nil
  end

  @spec read_config_provider() :: :auto | :native | :pi_rpc
  defp read_config_provider do
    ConfigOptions.get(:agent_provider)
  rescue
    # ConfigOptions agent may not be running (e.g. in tests)
    _ -> :auto
  catch
    :exit, _ -> :auto
  end

  @spec read_config_model() :: String.t() | nil
  defp read_config_model do
    ConfigOptions.get(:agent_model)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
