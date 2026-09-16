defmodule MingaAgent.Credentials.Snapshot do
  @moduledoc """
  Secret-free local credential classification captured from one acquisition.

  The snapshot records only credential sources and OAuth presence. API key
  values never leave `MingaAgent.Credentials` and cannot appear in status,
  events, errors, or diagnostics.
  """

  @enforce_keys [:provider_sources, :oauth_configured, :ollama_host]
  defstruct [:provider_sources, :oauth_configured, :ollama_host]

  @type source :: :env | :file
  @type t :: %__MODULE__{
          provider_sources: %{optional(String.t()) => source()},
          oauth_configured: boolean(),
          ollama_host: String.t()
        }

  @doc "Builds a secret-free credential snapshot."
  @spec new(%{optional(String.t()) => source()}, boolean(), String.t()) :: t()
  def new(provider_sources, oauth_configured, ollama_host)
      when is_map(provider_sources) and is_boolean(oauth_configured) and is_binary(ollama_host) do
    %__MODULE__{
      provider_sources: provider_sources,
      oauth_configured: oauth_configured,
      ollama_host: ollama_host
    }
  end

  @doc "Returns the configured source for one API-key provider."
  @spec provider_source(t(), String.t()) :: source() | nil
  def provider_source(%__MODULE__{provider_sources: sources}, provider) when is_binary(provider),
    do: Map.get(sources, provider)

  @doc "Returns whether any local API-key or OAuth credential is configured."
  @spec locally_configured?(t()) :: boolean()
  def locally_configured?(%__MODULE__{} = snapshot) do
    map_size(snapshot.provider_sources) > 0 or snapshot.oauth_configured
  end
end
