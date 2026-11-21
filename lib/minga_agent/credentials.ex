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

  A contributed model route may also have an entry under `routes.<route_id>.env`, a map of environment variable names to string values. Minga passes the map only to that route's requests and availability checks, and never interprets it. An empty value means "unset". `HOME`, `CLAUDE_CONFIG_DIR`, and `USERPROFILE` are rejected so a route entry cannot redirect another tool's login. Minga never reads or copies another tool's login.
  """

  @typedoc "A supported provider name."
  @type provider :: String.t()

  @typedoc "Source where a key was found."
  @type key_source :: :env | :file | :oauth | nil

  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.{ApiKey, OAuth, RouteOwned}
  alias MingaAgent.Credentials.Binding
  alias MingaAgent.InferenceRoute.Credential, as: RouteCredential
  alias MingaAgent.OAuth, as: OAuthFile

  @typedoc "Owner-visible credential readiness."
  @type readiness :: :checking | :configured | :unconfigured

  defmodule ProviderStatus do
    @moduledoc false
    @enforce_keys [:provider, :configured]
    defstruct [:provider, :configured, :source]

    @type t :: %__MODULE__{
            provider: String.t(),
            configured: boolean(),
            source: :env | :file | :oauth | nil
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

  @known_providers Map.keys(@env_vars)

  # A route entry must not redirect where another tool keeps its own login.
  @reserved_route_env ~w(HOME CLAUDE_CONFIG_DIR USERPROFILE)

  @typedoc "Opaque credential delivered to one contributed route."
  @type route_credential :: RouteCredential.t()

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
          {:ok, keyword()}
          | {:error, {:credential_unavailable, String.t()} | {:route_unavailable, String.t()}}
  def request_options(:none, _opts), do: {:ok, []}

  def request_options(%ApiKey{provider: provider, source: source} = credential, opts) do
    case resolve_exact_api_key(provider, source, opts) do
      {:ok, key} -> {:ok, [auth_mode: :api_key, api_key: key]}
      :error -> credential_error(credential)
    end
  end

  def request_options(%RouteOwned{route_id: route_id}, opts) do
    with {:ok, credential} <- route_credential(route_id, opts),
         do: {:ok, [route_credential: credential]}
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

  @doc "Acquires dispatch material and its secret-free replay binding in one resolution."
  @spec bind_request(ModelSelection.credential_ref(), Binding.t() | nil, keyword()) ::
          {:ok, Binding.t()} | {:error, term()}
  def bind_request(:none, _previous, _opts), do: {:ok, Binding.none()}

  def bind_request(%ApiKey{} = credential, previous, opts) do
    with {:ok, material} <- request_options(credential, opts),
         do: {:ok, Binding.api_key(material, previous)}
  end

  def bind_request(%RouteOwned{} = credential, _previous, opts) do
    with {:ok, material} <- request_options(credential, opts),
         do: {:ok, Binding.route(material, credential.route_id, credential.account_ref)}
  end

  def bind_request(%OAuth{} = credential, _previous, opts) do
    with {:ok, material} <- request_options(credential, opts),
         do: {:ok, Binding.oauth(material, credential.account_id, credential.source_id)}
  end

  @doc """
  Resolves the `routes.<route_id>.env` entry for one contributed route.

  A missing entry resolves to an empty env. Values are never logged; errors name only the route and the offending variable.
  """
  @spec route_credential(String.t(), keyword()) ::
          {:ok, route_credential()} | {:error, {:route_unavailable, String.t()}}
  def route_credential(route_id, opts \\ []) when is_binary(route_id) do
    opts
    |> acquire_stored_credentials()
    |> Map.get("routes")
    |> route_entry(route_id)
    |> route_env(route_id)
  end

  @spec route_entry(term(), String.t()) :: term()
  defp route_entry(routes, route_id) when is_map(routes), do: Map.get(routes, route_id)
  defp route_entry(_routes, _route_id), do: nil

  @spec route_env(term(), String.t()) ::
          {:ok, route_credential()} | {:error, {:route_unavailable, String.t()}}
  defp route_env(nil, _route_id), do: {:ok, RouteCredential.new(%{})}

  defp route_env(%{"env" => env}, route_id) when is_map(env),
    do: validate_route_env(env, route_id)

  defp route_env(%{"env" => _invalid}, route_id), do: invalid_route_entry(route_id)
  defp route_env(entry, _route_id) when is_map(entry), do: {:ok, RouteCredential.new(%{})}
  defp route_env(_entry, route_id), do: invalid_route_entry(route_id)

  @spec invalid_route_entry(String.t()) :: {:error, {:route_unavailable, String.t()}}
  defp invalid_route_entry(route_id),
    do: route_credential_error(route_id, "must be an object of string values")

  @spec validate_route_env(map(), String.t()) ::
          {:ok, route_credential()} | {:error, {:route_unavailable, String.t()}}
  defp validate_route_env(env, route_id) do
    Enum.reduce_while(env, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case route_env_entry(name, value) do
        {:keep, entry} ->
          {:cont, {:ok, Map.put(acc, name, entry)}}

        :unset ->
          {:cont, {:ok, acc}}

        :reserved ->
          {:halt,
           route_credential_error(
             route_id,
             "sets #{name}, which Minga never passes to model routes. Remove it"
           )}

        :invalid ->
          {:halt, route_credential_error(route_id, "must map variable names to string values")}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, RouteCredential.new(values)}
      {:error, _reason} = error -> error
    end
  end

  # Reserved names are matched case-insensitively, so `Home` or `userprofile` cannot slip through.
  @spec route_env_entry(term(), term()) :: {:keep, String.t()} | :unset | :reserved | :invalid
  defp route_env_entry(name, value) when is_binary(name) and name != "" and is_binary(value) do
    cond do
      String.upcase(name) in @reserved_route_env -> :reserved
      value == "" -> :unset
      true -> {:keep, value}
    end
  end

  defp route_env_entry(_name, _value), do: :invalid

  @spec route_credential_error(String.t(), String.t()) ::
          {:error, {:route_unavailable, String.t()}}
  defp route_credential_error(route_id, problem) do
    {:error,
     {:route_unavailable, "The routes.#{route_id}.env entry in credentials.json #{problem}."}}
  end

  @doc """
  Stores an API key for a provider in the credentials file.

  Creates the config directory and atomically replaces the existing file with mode 0600, following final symlinks without replacing the links.
  API-key updates are serialized within this BEAM node, including updates through different paths to the same file.
  Failures before rename leave the previous credentials intact.
  """
  @spec store(provider(), String.t(), keyword()) :: :ok | {:error, term()}
  def store(provider, key, opts \\ []) when is_binary(provider) and is_binary(key) do
    configured_path = credentials_path(opts)

    with :ok <- ensure_directory(Path.dirname(configured_path)) do
      update_api_keys(configured_path, &Map.put(&1, provider, key))
    end
  end

  @doc """
  Removes a stored API key, or the local OAuth entry for Codex.
  Environment variables are unaffected.
  """
  @spec revoke(provider(), keyword()) :: :ok | {:error, term()}
  def revoke(provider, opts \\ [])

  def revoke("openai_codex", opts) do
    OAuthFile.revoke_oauth_file(Keyword.get(opts, :oauth_path, oauth_path()))
  end

  def revoke(provider, opts) when is_binary(provider) do
    path = credentials_path(opts)
    update_api_keys(path, &Map.delete(&1, provider))
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

    Snapshot.new(sources, oauth_ref)
  end

  @doc """
  Returns local authentication status for each hosted provider.

  Each entry shows whether a key is configured and where it was found
  (`:env`, `:file`, `:oauth`, or `nil`). Keys themselves are never exposed.
  """
  @spec status(keyword() | Snapshot.t()) :: [provider_status()]
  def status(source \\ [])
  def status(opts) when is_list(opts), do: opts |> snapshot() |> status()

  def status(%Snapshot{} = snapshot) do
    standard =
      Enum.map(@known_providers, fn provider ->
        case Snapshot.provider_source(snapshot, provider) do
          source when source in [:env, :file] ->
            %ProviderStatus{
              provider: provider,
              configured: true,
              source: source
            }

          nil ->
            %ProviderStatus{
              provider: provider,
              configured: false,
              source: nil
            }
        end
      end)

    oauth_status =
      if is_struct(snapshot.oauth_ref, OAuth) do
        %ProviderStatus{
          provider: "openai_codex",
          configured: true,
          source: :oauth
        }
      else
        %ProviderStatus{
          provider: "openai_codex",
          configured: false,
          source: nil
        }
      end

    standard ++ [oauth_status]
  end

  @doc """
  Returns true if any local API-key or OAuth credential is configured.

  This predicate never probes the network.
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

  @doc """
  Returns the path to `~/.config/minga/oauth.json` (XDG-aware).
  """
  @spec oauth_path() :: String.t()
  def oauth_path, do: MingaAgent.OAuth.oauth_path()

  @doc """
  Pins the exact OpenAI Codex account in Minga's explicit OAuth file.

  ReqLLM performs refresh within Minga's OAuth file guard. Tokens returned while pinning are discarded; only the provider, provider key, account id, and exact configured path remain.
  """
  @spec pin_oauth(:openai_codex, String.t()) :: {:ok, OAuth.t()} | {:error, term()}
  def pin_oauth(:openai_codex, path) when is_binary(path) do
    configured = Path.absname(path)

    with {:ok, resolved} <- OAuthFile.resolve_oauth_file(configured),
         "openai-codex" <- Map.get(resolved, :provider_key),
         ^configured <- Map.get(resolved, :oauth_file),
         account_id when is_binary(account_id) and account_id != "" <-
           Map.get(resolved, :account_id) do
      {:ok, OAuth.new(account_id, configured)}
    else
      {:error, _reason} = error -> error
      _mismatch -> {:error, :oauth_identity_mismatch}
    end
  end

  @spec local_oauth_identity(String.t()) :: OAuth.t() | nil
  defp local_oauth_identity(path) do
    configured = Path.absname(path)
    provider_key = MingaAgent.OAuth.provider_key()

    with {:ok, content} when content != "" <- File.read(configured),
         {:ok, data} when is_map(data) <- JSON.decode(content),
         entry when is_map(entry) <- Map.get(data, provider_key),
         account_id when is_binary(account_id) and account_id != "" <-
           Map.get(entry, "accountId") || Map.get(entry, "account_id") ||
             oauth_account_from_entry(entry) do
      OAuth.new(account_id, configured)
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
        resolver.(:openai_codex, oauth_file: Path.absname(path))

      nil ->
        OAuthFile.resolve_oauth_file(path)
    end
  end

  @spec oauth_resolution_matches?(map(), OAuth.t(), String.t()) :: boolean()
  defp oauth_resolution_matches?(resolved, credential, path) do
    credential.provider == :openai_codex and
      Map.get(resolved, :provider_key) == credential.provider_key and
      Map.get(resolved, :account_id) == credential.account_id and
      Map.get(resolved, :oauth_file) == Path.absname(path)
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
      {:ok, content} -> decode_credentials_file(content)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec decode_credentials_file(String.t()) :: {:ok, map()} | {:error, :invalid_credentials_file}
  defp decode_credentials_file(content) do
    case JSON.decode(content) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _invalid -> {:error, :invalid_credentials_file}
    end
  end

  # Preserve filesystem traversal order, including `..` after symlinked directories.
  @spec credential_write_target(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  defp credential_write_target(_path, 40), do: {:error, :eloop}

  defp credential_write_target(path, depth) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, link} <- File.read_link(path) do
          credential_write_target(link_target(path, link), depth + 1)
        end

      {:ok, _metadata} ->
        {:ok, path}

      {:error, :enoent} ->
        {:ok, path}

      {:error, _reason} = error ->
        error
    end
  end

  @spec link_target(String.t(), String.t()) :: String.t()
  defp link_target(path, link) do
    if Path.type(link) == :absolute, do: link, else: Path.dirname(path) <> "/" <> link
  end

  @spec update_api_keys(String.t(), (map() -> map())) :: :ok | {:error, term()}
  defp update_api_keys(configured_path, update) do
    :global.trans(
      {{__MODULE__, :api_key_updates}, self()},
      fn -> merge_api_keys(configured_path, update) end,
      [node()],
      :infinity
    )
    |> lock_result()
  end

  @spec lock_result(:ok | {:error, term()} | :aborted) :: :ok | {:error, term()}
  defp lock_result(:aborted), do: {:error, :credential_file_lock_aborted}
  defp lock_result(result), do: result

  @spec merge_api_keys(String.t(), (map() -> map())) :: :ok | {:error, term()}
  defp merge_api_keys(configured_path, update) do
    with {:ok, path} <- credential_write_target(configured_path, 0),
         {:ok, existing} <- read_credentials_file(path) do
      replace_credentials_file(path, :json.format(update.(existing)))
    end
  end

  @spec replace_credentials_file(String.t(), iodata()) :: :ok | {:error, term()}
  defp replace_credentials_file(path, contents) do
    temporary = path <> ".#{System.unique_integer([:positive, :monotonic])}.tmp"

    case :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive]) do
      {:ok, io} ->
        result =
          with :ok <- File.chmod(temporary, 0o600),
               :ok <- :file.write(io, contents) do
            :file.sync(io)
          end

        closed = :file.close(io)

        case publish_credentials_file(result, closed, temporary, path) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            File.rm(temporary)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec publish_credentials_file(
          :ok | {:error, term()},
          :ok | {:error, term()},
          String.t(),
          String.t()
        ) ::
          :ok | {:error, term()}
  defp publish_credentials_file(:ok, :ok, temporary, path), do: File.rename(temporary, path)
  defp publish_credentials_file({:error, _reason} = error, _closed, _temporary, _path), do: error
  defp publish_credentials_file(:ok, {:error, _reason} = error, _temporary, _path), do: error

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
