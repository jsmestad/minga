defmodule MingaAgent.Credentials.Secret do
  @moduledoc """
  Ephemeral credential material for a guarded credential operation.

  This holder is not encryption.
  Inspection is redacted and JSON encoding is deliberately unsupported.
  Only the named credential operations below open it; consumers must not pattern-match its representation or retain it in public outcomes.
  """

  alias MingaAgent.Credentials

  @derive {Inspect, only: []}
  @enforce_keys [:material]
  defstruct [:material]

  @opaque t :: %__MODULE__{material: String.t()}

  @doc "Seals API-key text for an immediate guarded installation."
  @spec new(String.t()) :: t()
  def new(material) when is_binary(material),
    do: %__MODULE__{material: material}

  @doc "Stores an API key with the existing writer, then activates the current runtime."
  @spec write_api_key(t(), String.t(), keyword()) ::
          :ok | {:error, :invalid_secret | :credential_store_failed}
  def write_api_key(%__MODULE__{material: key}, provider, opts)
      when is_binary(key) and byte_size(key) > 0 and is_binary(provider) do
    if is_binary(Credentials.env_var_for(provider)) and String.valid?(key) and
         String.trim(key) != "" and :binary.match(key, [<<0>>, "\r", "\n"]) == :nomatch do
      store_api_key(provider, key, opts)
    else
      {:error, :invalid_secret}
    end
  end

  def write_api_key(_secret, _provider, _opts), do: {:error, :invalid_secret}

  @spec store_api_key(String.t(), String.t(), keyword()) ::
          :ok | {:error, :credential_store_failed}
  defp store_api_key(provider, key, opts) do
    case Credentials.store(provider, key, opts) do
      :ok -> activate_runtime(provider, key, opts)
      {:error, _reason} -> {:error, :credential_store_failed}
    end
  end

  @spec activate_runtime(String.t(), String.t(), keyword()) :: :ok
  defp activate_runtime(provider, key, opts) do
    # Explicit environment snapshots are isolated credential contexts. They must
    # not mutate the real process environment that their readers do not consume.
    case Keyword.fetch(opts, :env) do
      {:ok, _isolated_environment} -> :ok
      :error -> System.put_env(Credentials.env_var_for(provider), key)
    end
  end
end
