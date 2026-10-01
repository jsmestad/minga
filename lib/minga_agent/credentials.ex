defmodule MingaAgent.Credentials do
  @moduledoc """
  API key storage, resolution, and management for agent providers.

  Keys are stored in `~/.config/minga/credentials.json` with restrictive
  file permissions (0600). Environment variables always take precedence
  over stored keys so existing setups are never broken.

  Resolution order:
  1. Environment variable (e.g. `ANTHROPIC_API_KEY`)
  2. Credentials file

  Keys are never logged, never included in session exports, and never
  sent to `*Messages*`.
  """

  @typedoc "A supported provider name."
  @type provider :: String.t()

  @typedoc "Source where a key was found."
  @type key_source :: :env | :file | :oauth | nil

  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.{ApiKey, None, OAuth}

  @typedoc "Live Ollama availability, kept separate from local configuration."
  @type ollama_availability :: :pending | :available | {:unavailable, term()}

  @typedoc "Owner-visible credential readiness."
  @type readiness :: :checking | :configured | :unconfigured

  defmodule ProviderStatus do
    @moduledoc false
    @enforce_keys [:provider, :configured, :availability]
    defstruct [:provider, :configured, :source, :availability]

    @type t :: %__MODULE__{
            provider: String.t(),
            configured: boolean(),
            source: :env | :file | :local | :oauth | nil,
            availability: :not_applicable | MingaAgent.Credentials.ollama_availability()
          }
  end

  @typedoc "Status entry for a single provider."
  @type provider_status :: ProviderStatus.t()

  @credentials_filename "credentials.json"

  # Maps provider names to their environment variable.
  @env_vars %{
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "google" => "GOOGLE_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY",
    "groq" => "GROQ_API_KEY",
    "mistral" => "MISTRAL_API_KEY",
    "deepseek" => "DEEPSEEK_API_KEY"
  }

  # Maps provider names to their API key dashboard URLs.
  @dashboard_urls %{
    "anthropic" => "https://console.anthropic.com/settings/keys",
    "openai" => "https://platform.openai.com/api-keys",
    "google" => "https://aistudio.google.com/apikey",
    "openrouter" => "https://openrouter.ai/keys",
    "groq" => "https://console.groq.com/keys",
    "mistral" => "https://console.mistral.ai/api-keys",
    "deepseek" => "https://platform.deepseek.com/api_keys"
  }

  # Ollama doesn't use an API key; it's auto-detected when the local server
  # is running. We store the host URL instead.
  @ollama_host_var "OLLAMA_HOST"
  @ollama_default_host "http://localhost:11434"

  @known_providers Map.keys(@env_vars)

  @doc """
  Returns the list of known provider names.
  """
  @spec known_providers() :: [provider()]
  def known_providers, do: @known_providers

  @doc """
  Resolves an API key for the given provider.

  Checks the environment variable first, then the credentials file.
  Returns `{:ok, key, source}` if found, or `:error` if no key is
  configured anywhere.
  """
  @spec resolve(provider(), keyword()) :: {:ok, String.t(), key_source()} | :error
  def resolve(provider, opts \\ []) when is_binary(provider) do
    case resolve_from_env(provider, opts) do
      {:ok, key} -> {:ok, key, :env}
      :error -> resolve_from_file(provider, opts)
    end
  end

  @doc """
  Resolves one tagged credential reference for a single ReqLLM request.

  API-key sources are exact. OAuth is refreshed by ReqLLM from Minga's explicit
  file and the returned provider, file, and account identities must match the
  pin before the access token is exposed to the caller.
  """
  @spec request_options(ModelSelection.credential_ref(), keyword()) ::
          {:ok, keyword()} | {:error, {:credential_unavailable, String.t()}}
  def request_options(%None{}, _opts), do: {:ok, [auth_mode: :none]}

  def request_options(%ApiKey{provider: provider, source: source} = credential, opts) do
    case resolve_exact_api_key(provider, source, opts) do
      {:ok, key} -> {:ok, [auth_mode: :api_key, api_key: key]}
      :error -> credential_error(credential)
    end
  end

  def request_options(%OAuth{} = credential, opts) do
    path = credential.oauth_path || Keyword.get(opts, :oauth_path, oauth_path())

    with true <- OAuth.new(credential.account_id, path).source_id == credential.source_id,
         {:ok, resolved} <- resolve_req_llm_oauth(path, opts),
         true <- oauth_resolution_matches?(resolved, credential, path),
         token when is_binary(token) and token != "" <- Map.get(resolved, :token) do
      {:ok,
       [
         auth_mode: :oauth,
         access_token: token,
         chatgpt_account_id: credential.account_id
       ]}
    else
      _unavailable -> credential_error(credential)
    end
  end

  @doc """
  Stores an API key for a provider in the credentials file.

  Creates the config directory and file if they don't exist. Sets
  file permissions to 0600 (owner read/write only).
  """
  @spec store(provider(), String.t(), keyword()) :: :ok | {:error, term()}
  def store(provider, key, opts \\ []) when is_binary(provider) and is_binary(key) do
    path = credentials_path(opts)
    dir = Path.dirname(path)

    with :ok <- ensure_directory(dir),
         {:ok, existing} <- read_credentials_file(path),
         updated = Map.put(existing, provider, key),
         json = :json.format(updated),
         :ok <- File.write(path, json) do
      File.chmod(path, 0o600)
    end
  end

  @doc """
  Removes a stored API key for a provider.

  Only removes from the credentials file. Environment variables are
  unaffected (and will still be used if set).
  """
  @spec revoke(provider(), keyword()) :: :ok | {:error, term()}
  def revoke(provider, opts \\ []) when is_binary(provider) do
    revoke_api_key(provider, opts)
    |> merge_revoke_result(revoke_oauth_entry(provider))
  end

  @doc """
  Acquires one secret-free local credential snapshot.

  The credentials file is read once. Environment values retain precedence over
  stored values, and only their configured source is retained.
  """
  @spec snapshot(keyword()) :: Snapshot.t()
  def snapshot(opts \\ []) do
    stored = acquire_stored_credentials(opts)

    sources =
      Map.new(credential_owners(stored), fn provider ->
        {provider, configured_source(provider, stored, opts)}
      end)
      |> Map.reject(fn {_provider, source} -> is_nil(source) end)

    oauth_ref =
      case Keyword.get(opts, :oauth_identity_probe) do
        probe when is_function(probe, 0) -> probe.()
        nil -> local_oauth_identity(Keyword.get(opts, :oauth_path, oauth_path()))
      end

    Snapshot.new(sources, oauth_ref, ollama_host(opts))
  end

  @doc """
  Returns local auth status plus an explicit Ollama availability state.

  Each entry shows whether a key is configured and where it was found
  (`:env`, `:file`, `:oauth`, `:local`, or `nil`). Keys themselves are never exposed.
  Calling this function never probes the network; Ollama is `:pending` until an
  owner executes `ollama_availability/2` outside its mailbox.
  """
  @spec status(keyword()) :: [provider_status()]
  def status(opts \\ []) when is_list(opts), do: opts |> snapshot() |> status(:pending)

  @doc "Returns status entries from one acquired snapshot and live Ollama result."
  @spec status(Snapshot.t(), ollama_availability()) :: [provider_status()]
  def status(%Snapshot{} = snapshot, availability) do
    standard =
      Enum.map(@known_providers, fn provider ->
        case Snapshot.provider_source(snapshot, provider) do
          source when source in [:env, :file] ->
            %ProviderStatus{
              provider: provider,
              configured: true,
              source: source,
              availability: :not_applicable
            }

          nil ->
            %ProviderStatus{
              provider: provider,
              configured: false,
              source: nil,
              availability: :not_applicable
            }
        end
      end)

    oauth_status =
      if is_struct(snapshot.oauth_ref, OAuth) do
        %ProviderStatus{
          provider: "openai_codex",
          configured: true,
          source: :oauth,
          availability: :not_applicable
        }
      else
        %ProviderStatus{
          provider: "openai_codex",
          configured: false,
          source: nil,
          availability: :not_applicable
        }
      end

    ollama_status = %ProviderStatus{
      provider: "ollama",
      configured: availability == :available,
      source: if(availability == :available, do: :local, else: nil),
      availability: availability
    }

    standard ++ [oauth_status, ollama_status]
  end

  @doc """
  Returns true if any local API-key or OAuth credential is configured.

  This predicate never probes the network. Owners combine it with an explicit
  `ollama_availability/2` result when automatic local discovery is relevant.
  """
  @spec any_configured?(keyword() | Snapshot.t()) :: boolean()
  def any_configured?(source \\ [])

  def any_configured?(opts) when is_list(opts), do: opts |> snapshot() |> any_configured?()

  def any_configured?(%Snapshot{} = snapshot), do: Snapshot.locally_configured?(snapshot)

  @doc """
  Returns the environment variable name for a provider, or nil if unknown.
  """
  @spec env_var_for(provider()) :: String.t() | nil
  def env_var_for(provider) when is_binary(provider) do
    Map.get(@env_vars, String.downcase(provider))
  end

  @doc """
  Returns the API key dashboard URL for a provider, or nil if unknown.
  """
  @spec dashboard_url_for(provider()) :: String.t() | nil
  def dashboard_url_for(provider) when is_binary(provider) do
    Map.get(@dashboard_urls, String.downcase(provider))
  end

  @doc """
  Returns the Ollama host URL. Checks `OLLAMA_HOST` env var first,
  then falls back to the default localhost URL.
  """
  @spec ollama_host() :: String.t()
  def ollama_host, do: ollama_host([])

  @doc "Returns the Ollama host using an optional captured environment map."
  @spec ollama_host(keyword()) :: String.t()
  def ollama_host(opts) when is_list(opts) do
    env = Keyword.get(opts, :env, %{})

    case Map.fetch(env, @ollama_host_var) do
      {:ok, host} when is_binary(host) and host != "" -> host
      {:ok, _missing} -> @ollama_default_host
      :error -> System.get_env(@ollama_host_var) || @ollama_default_host
    end
  end

  @doc """
  Returns true if Ollama appears to be running locally.

  Makes a quick HTTP request to the Ollama API tags endpoint.
  Returns false on connection errors or timeouts.
  """
  @spec ollama_available?() :: boolean()
  def ollama_available?, do: ollama_availability(snapshot()) == :available

  @doc "Checks live Ollama availability for a previously acquired snapshot."
  @spec ollama_availability(Snapshot.t(), keyword()) :: ollama_availability()
  def ollama_availability(%Snapshot{} = snapshot, opts \\ []) do
    result =
      case Keyword.get(opts, :ollama_probe) do
        probe when is_function(probe, 1) -> probe.(snapshot.ollama_host)
        probe when is_function(probe, 0) -> probe.()
        nil -> request_ollama_tags(snapshot.ollama_host)
      end

    normalize_ollama_result(result)
  rescue
    error -> {:unavailable, {:exception, error.__struct__}}
  catch
    :exit, reason -> {:unavailable, {:exit, reason}}
  end

  @spec acquire_stored_credentials(keyword()) :: map()
  defp acquire_stored_credentials(opts) do
    path = credentials_path(opts)

    result =
      case Keyword.get(opts, :credentials_reader) do
        reader when is_function(reader, 1) -> reader.(path)
        nil -> read_credentials_file(path)
      end

    case result do
      {:ok, credentials} when is_map(credentials) -> credentials
      _error -> %{}
    end
  end

  @spec credential_owners(map()) :: [provider()]
  defp credential_owners(stored) do
    stored
    |> Map.keys()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Kernel.++(@known_providers)
    |> Enum.uniq()
  end

  @spec configured_source(provider(), map(), keyword()) :: :env | :file | nil
  defp configured_source(provider, stored, opts) do
    case resolve_from_env(provider, opts) do
      {:ok, _key} -> :env
      :error -> configured_file_source(stored, provider)
    end
  end

  @spec configured_file_source(map(), provider()) :: :file | nil
  defp configured_file_source(stored, provider) do
    case Map.get(stored, provider) do
      key when is_binary(key) and key != "" -> :file
      _missing -> nil
    end
  end

  @spec request_ollama_tags(String.t()) :: term()
  defp request_ollama_tags(host) do
    :httpc.request(:get, {~c"#{host}/api/tags", []}, [{:timeout, 2000}], [])
  end

  @spec normalize_ollama_result(term()) :: ollama_availability()
  defp normalize_ollama_result(true), do: :available
  defp normalize_ollama_result(:available), do: :available
  defp normalize_ollama_result(false), do: {:unavailable, :probe_failed}
  defp normalize_ollama_result({:unavailable, _reason} = unavailable), do: unavailable

  defp normalize_ollama_result({:ok, {{_version, 200, _message}, _headers, _body}}),
    do: :available

  defp normalize_ollama_result({:ok, {{_version, status, _message}, _headers, _body}}),
    do: {:unavailable, {:http_status, status}}

  defp normalize_ollama_result({:error, reason}), do: {:unavailable, reason}
  defp normalize_ollama_result(other), do: {:unavailable, {:unexpected_result, other}}

  @doc """
  Returns the path to `~/.config/minga/oauth.json` (XDG-aware).
  """
  @spec oauth_path() :: String.t()
  def oauth_path, do: MingaAgent.OAuth.oauth_path()

  @doc """
  Pins the exact OpenAI Codex account in Minga's explicit OAuth file.

  ReqLLM owns refresh locking and persistence. Tokens returned while pinning are
  discarded; only the provider, provider key, account id, and exact path remain.
  """
  @spec pin_oauth(:openai_codex, String.t()) :: {:ok, OAuth.t()} | {:error, term()}
  def pin_oauth(:openai_codex, path) when is_binary(path) do
    expanded_path = Path.expand(path)

    with {:ok, resolved} <- ReqLLM.OAuth.resolve(:openai_codex, oauth_file: expanded_path),
         "openai-codex" <- Map.get(resolved, :provider_key),
         ^expanded_path <- Map.get(resolved, :oauth_file),
         account_id when is_binary(account_id) and account_id != "" <-
           Map.get(resolved, :account_id) do
      {:ok, OAuth.new(account_id, expanded_path)}
    else
      {:error, _reason} = error -> error
      _mismatch -> {:error, :oauth_identity_mismatch}
    end
  end

  @spec local_oauth_identity(String.t()) :: OAuth.t() | nil
  defp local_oauth_identity(path) do
    expanded_path = Path.expand(path)
    provider_key = MingaAgent.OAuth.provider_key()

    with {:ok, content} when content != "" <- File.read(expanded_path),
         {:ok, data} when is_map(data) <- JSON.decode(content),
         entry when is_map(entry) <- Map.get(data, provider_key),
         account_id when is_binary(account_id) and account_id != "" <-
           Map.get(entry, "accountId") || Map.get(entry, "account_id") ||
             oauth_account_from_entry(entry) do
      OAuth.new(account_id, expanded_path)
    else
      _missing -> nil
    end
  end

  @spec oauth_account_from_entry(map()) :: String.t() | nil
  defp oauth_account_from_entry(entry) do
    access = Map.get(entry, "access") || Map.get(entry, "access_token")
    MingaAgent.OAuth.account_id_from_token(access)
  end

  @spec resolve_req_llm_oauth(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp resolve_req_llm_oauth(path, opts) do
    case Keyword.get(opts, :oauth_resolver) do
      resolver when is_function(resolver, 2) ->
        resolver.(:openai_codex, oauth_file: Path.expand(path))

      nil ->
        ReqLLM.OAuth.resolve(:openai_codex, oauth_file: Path.expand(path))
    end
  end

  @spec oauth_resolution_matches?(map(), OAuth.t(), String.t()) :: boolean()
  defp oauth_resolution_matches?(resolved, credential, path) do
    credential.provider == :openai_codex and
      Map.get(resolved, :provider_key) == credential.provider_key and
      Map.get(resolved, :account_id) == credential.account_id and
      Map.get(resolved, :oauth_file) == Path.expand(path)
  end

  @spec credential_error(ModelSelection.credential_ref()) ::
          {:error, {:credential_unavailable, String.t()}}
  defp credential_error(credential) do
    {:error, {:credential_unavailable, ModelSelection.credential_id(credential)}}
  end

  @spec resolve_exact_api_key(provider(), :env | :file, keyword()) ::
          {:ok, String.t()} | :error
  defp resolve_exact_api_key(provider, :env, opts), do: resolve_from_env(provider, opts)

  defp resolve_exact_api_key(provider, :file, opts) do
    case resolve_from_file(provider, opts) do
      {:ok, key, :file} -> {:ok, key}
      :error -> :error
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec revoke_api_key(provider(), keyword()) :: :ok | {:error, term()}
  defp revoke_api_key(provider, opts) do
    path = credentials_path(opts)

    case read_credentials_file(path) do
      {:ok, existing} ->
        updated = Map.delete(existing, provider)
        json = :json.format(updated)

        with :ok <- File.write(path, json) do
          File.chmod(path, 0o600)
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec revoke_oauth_entry(provider()) :: :ok | {:error, term()}
  defp revoke_oauth_entry("openai_codex") do
    path = oauth_path()

    with {:ok, content} when content != "" <- File.read(path),
         {:ok, existing} when is_map(existing) <- JSON.decode(content) do
      updated = Map.delete(existing, MingaAgent.OAuth.provider_key())
      json = :json.format(updated)

      case File.write(path, json) do
        :ok -> File.chmod(path, 0o600)
        error -> error
      end
    else
      {:error, :enoent} -> :ok
      _ -> :ok
    end
  end

  defp revoke_oauth_entry(_provider), do: :ok

  defp merge_revoke_result(:ok, :ok), do: :ok
  defp merge_revoke_result({:error, _} = err, _), do: err
  defp merge_revoke_result(_, {:error, _} = err), do: err

  @spec resolve_from_env(provider(), keyword()) :: {:ok, String.t()} | :error
  defp resolve_from_env(provider, opts) do
    case Map.get(@env_vars, String.downcase(provider)) do
      nil ->
        :error

      var_name ->
        env = Keyword.get(opts, :env, %{})

        value =
          if Map.has_key?(env, var_name),
            do: env[var_name],
            else: System.get_env(var_name)

        case value do
          nil -> :error
          "" -> :error
          key -> {:ok, key}
        end
    end
  end

  @spec resolve_from_file(provider(), keyword()) :: {:ok, String.t(), :file} | :error
  defp resolve_from_file(provider, opts) do
    path = credentials_path(opts)

    case read_credentials_file(path) do
      {:ok, creds} ->
        case Map.get(creds, provider) do
          nil -> :error
          "" -> :error
          key -> {:ok, key, :file}
        end

      {:error, _} ->
        :error
    end
  end

  @spec read_credentials_file(String.t()) :: {:ok, map()} | {:error, term()}
  defp read_credentials_file(path) do
    case File.read(path) do
      {:ok, ""} -> {:ok, %{}}
      {:ok, content} -> JSON.decode(content)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_directory(String.t()) :: :ok | {:error, term()}
  defp ensure_directory(dir) do
    File.mkdir_p(dir)
  end

  @spec credentials_path(keyword()) :: String.t()
  defp credentials_path(opts) do
    config_dir =
      Keyword.get(opts, :config_dir) ||
        System.get_env("XDG_CONFIG_HOME") ||
        Path.join(System.user_home!(), ".config")

    Path.join([config_dir, "minga", @credentials_filename])
  end
end
