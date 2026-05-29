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

  defmodule ProviderStatus do
    @moduledoc false
    @enforce_keys [:provider, :configured]
    defstruct [:provider, :configured, :source]

    @type t :: %__MODULE__{
            provider: String.t(),
            configured: boolean(),
            source: :env | :file | :local | :oauth | nil
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
  @spec resolve(provider()) :: {:ok, String.t(), key_source()} | :error
  def resolve(provider) when is_binary(provider) do
    case resolve_from_env(provider) do
      {:ok, key} -> {:ok, key, :env}
      :error -> resolve_from_file(provider)
    end
  end

  @doc """
  Stores an API key for a provider in the credentials file.

  Creates the config directory and file if they don't exist. Sets
  file permissions to 0600 (owner read/write only).
  """
  @spec store(provider(), String.t()) :: :ok | {:error, term()}
  def store(provider, key) when is_binary(provider) and is_binary(key) do
    path = credentials_path()
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
  @spec revoke(provider()) :: :ok | {:error, term()}
  def revoke(provider) when is_binary(provider) do
    revoke_api_key(provider)
    |> merge_revoke_result(revoke_oauth_entry(provider))
  end

  @doc """
  Returns the auth status for all known providers plus Ollama and OpenAI OAuth.

  Each entry shows whether a key is configured and where it was found
  (`:env`, `:file`, `:oauth`, `:local`, or `nil`). Keys themselves are never exposed.
  """
  @spec status() :: [provider_status()]
  def status do
    standard =
      Enum.map(@known_providers, fn provider ->
        case resolve(provider) do
          {:ok, _key, source} ->
            %ProviderStatus{provider: provider, configured: true, source: source}

          :error ->
            %ProviderStatus{provider: provider, configured: false, source: nil}
        end
      end)

    oauth_status =
      if oauth_configured?() do
        %ProviderStatus{provider: "openai_codex", configured: true, source: :oauth}
      else
        %ProviderStatus{provider: "openai_codex", configured: false, source: nil}
      end

    ollama_up = ollama_available?()

    ollama_status = %ProviderStatus{
      provider: "ollama",
      configured: ollama_up,
      source: if(ollama_up, do: :local, else: nil)
    }

    standard ++ [oauth_status, ollama_status]
  end

  @doc """
  Returns true if any provider has a configured API key.
  """
  @spec any_configured?() :: boolean()
  def any_configured? do
    Enum.any?(status(), fn s -> s.configured end)
  end

  @doc """
  Extracts the provider name from a model string like "anthropic:claude-sonnet-4-20250514".

  Returns `"anthropic"` for bare model names (no prefix), since Anthropic
  is the default provider.
  """
  @spec provider_from_model(String.t()) :: provider()
  def provider_from_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _model_name] -> String.downcase(provider)
      [_bare_model] -> "anthropic"
    end
  end

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
  def ollama_host do
    System.get_env(@ollama_host_var) || @ollama_default_host
  end

  @doc """
  Returns true if Ollama appears to be running locally.

  Makes a quick HTTP request to the Ollama API tags endpoint.
  Returns false on connection errors or timeouts.
  """
  @spec ollama_available?() :: boolean()
  # NOTE: This check blocks the calling process for up to 2 seconds when Ollama
  # isn't running. Called during resolve_auto/0 and status/0, so agent startup
  # may be delayed by that amount if Ollama is unreachable.
  def ollama_available? do
    host = ollama_host()

    case :httpc.request(:get, {~c"#{host}/api/tags", []}, [{:timeout, 2000}], []) do
      {:ok, {{_, 200, _}, _, _}} -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Returns the path to `~/.config/minga/oauth.json` (XDG-aware).
  """
  @spec oauth_path() :: String.t()
  def oauth_path, do: MingaAgent.OAuth.oauth_path()

  @doc """
  Returns true if an `openai-codex` entry exists in `oauth.json`.
  """
  @spec oauth_configured?() :: boolean()
  def oauth_configured? do
    path = oauth_path()

    case File.read(path) do
      {:ok, content} when content != "" ->
        case Jason.decode(content) do
          {:ok, %{"openai-codex" => %{"access" => access}}}
          when is_binary(access) and access != "" ->
            true

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec revoke_api_key(provider()) :: :ok | {:error, term()}
  defp revoke_api_key(provider) do
    path = credentials_path()

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
         {:ok, existing} when is_map(existing) <- Jason.decode(content) do
      updated = Map.delete(existing, MingaAgent.OAuth.provider_key())
      json = Jason.encode!(updated, pretty: true)

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

  @spec resolve_from_env(provider()) :: {:ok, String.t()} | :error
  defp resolve_from_env(provider) do
    case Map.get(@env_vars, String.downcase(provider)) do
      nil ->
        :error

      var_name ->
        case System.get_env(var_name) do
          nil -> :error
          "" -> :error
          key -> {:ok, key}
        end
    end
  end

  @spec resolve_from_file(provider()) :: {:ok, String.t(), :file} | :error
  defp resolve_from_file(provider) do
    path = credentials_path()

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
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec credentials_path() :: String.t()
  defp credentials_path do
    config_dir = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([config_dir, "minga", @credentials_filename])
  end
end
