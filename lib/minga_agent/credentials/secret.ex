defmodule MingaAgent.Credentials.Secret do
  @moduledoc """
  Ephemeral credential material for a guarded credential operation.

  This holder is not encryption.
  Inspection is redacted and JSON encoding is deliberately unsupported.
  Only the named credential operations below open it; consumers must not pattern-match its representation or retain it in public outcomes.
  """

  alias MingaAgent.Credentials
  alias MingaAgent.OAuth

  @derive {Inspect, only: []}
  @enforce_keys [:material]
  defstruct [:material]

  @opaque t :: %__MODULE__{material: String.t() | OAuth.token_response()}

  @doc "Seals API-key text or acquired OAuth tokens for an immediate guarded installation."
  @spec new(String.t() | OAuth.token_response()) :: t()
  def new(material) when is_binary(material) or is_map(material),
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

  @doc "Writes acquired OAuth material only when it matches any pinned account."
  @spec write_oauth(t(), String.t(), String.t() | nil) ::
          :ok | {:error, :invalid_secret | :credential_store_failed | :account_mismatch}
  def write_oauth(%__MODULE__{material: tokens}, path, expected_account)
      when is_map(tokens) and is_binary(path) do
    case tokens do
      %{access: access, refresh: refresh, expires: expires, account_id: account_id}
      when is_binary(access) and byte_size(access) > 0 and
             (is_binary(refresh) or is_nil(refresh)) and
             (is_integer(expires) or is_nil(expires)) and
             (is_binary(account_id) or is_nil(account_id)) ->
        write_oauth_for_account(tokens, path, account_id, expected_account)

      _invalid ->
        {:error, :invalid_secret}
    end
  end

  def write_oauth(_secret, _path, _expected_account), do: {:error, :invalid_secret}

  @spec write_oauth_for_account(
          OAuth.token_response(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) ::
          :ok | {:error, :credential_store_failed | :account_mismatch}
  defp write_oauth_for_account(tokens, path, account, expected)
       when is_nil(expected) or account == expected,
       do: store_oauth(tokens, path)

  defp write_oauth_for_account(_tokens, _path, _account, _expected),
    do: {:error, :account_mismatch}

  @doc "Opens sealed redirect text only for completion of an owned OAuth flow."
  @spec complete_manual_oauth(t(), String.t(), keyword()) :: OAuth.Flow.connection_result()
  def complete_manual_oauth(%__MODULE__{material: redirect}, flow_ref, opts)
      when is_binary(redirect),
      do: OAuth.Flow.complete_bound_manual(flow_ref, redirect, opts)

  def complete_manual_oauth(_secret, _flow_ref, _opts), do: {:error, :invalid_input}

  @spec store_oauth(OAuth.token_response(), String.t()) ::
          :ok | {:error, :credential_store_failed}
  defp store_oauth(tokens, path) do
    case OAuth.write_oauth_file(tokens, path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :credential_store_failed}
    end
  end

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
