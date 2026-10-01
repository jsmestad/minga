defmodule MingaAgent.Credentials.Snapshot do
  @moduledoc """
  Secret-free local credential classification captured from one acquisition.

  API key values and OAuth tokens never leave `MingaAgent.Credentials`. OAuth
  presence is represented by its exact provider/account identity when the local
  file supplies one; activation still pins and refreshes through ReqLLM.
  """

  alias MingaAgent.ModelSelection.Credential.OAuth

  @enforce_keys [:provider_sources, :oauth_ref, :ollama_host]
  defstruct @enforce_keys

  @type source :: :env | :file
  @type t :: %__MODULE__{
          provider_sources: %{optional(String.t()) => source()},
          oauth_ref: OAuth.t() | nil,
          ollama_host: String.t()
        }

  @doc "Builds a secret-free credential snapshot from an exact OAuth identity."
  @spec new(%{optional(String.t()) => source()}, OAuth.t() | nil, String.t()) :: t()
  def new(provider_sources, oauth_ref, ollama_host)
      when is_map(provider_sources) and
             (is_struct(oauth_ref, OAuth) or is_nil(oauth_ref)) and
             is_binary(ollama_host) do
    %__MODULE__{
      provider_sources: provider_sources,
      oauth_ref: oauth_ref,
      ollama_host: ollama_host
    }
  end

  @doc "Returns the configured source for one API-key provider."
  @spec provider_source(t(), String.t()) :: source() | nil
  def provider_source(%__MODULE__{provider_sources: sources}, provider) when is_binary(provider),
    do: Map.get(sources, provider)

  @doc "Returns the exact local OAuth identity, if the snapshot contained one."
  @spec oauth_ref(t()) :: OAuth.t() | nil
  def oauth_ref(%__MODULE__{oauth_ref: oauth_ref}), do: oauth_ref

  @doc "Returns whether any local API-key or exact OAuth identity is configured."
  @spec locally_configured?(t()) :: boolean()
  def locally_configured?(%__MODULE__{} = snapshot) do
    map_size(snapshot.provider_sources) > 0 or not is_nil(snapshot.oauth_ref)
  end
end
