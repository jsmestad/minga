defmodule Minga.Agent.Credentials do
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

  require Logger

  @typedoc "A supported provider name."
  @type provider :: String.t()

  @typedoc "Source where a key was found."
  @type key_source :: :env | :file | nil

  @typedoc "Status entry for a single provider."
  @type provider_status :: %{
          provider: provider(),
          configured: boolean(),
          source: key_source()
        }

  @credentials_filename "credentials.json"

  # Maps provider names to their environment variable.
  @env_vars %{
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "google" => "GOOGLE_API_KEY"
  }

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
         json = Jason.encode!(updated, pretty: true),
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
    path = credentials_path()

    case read_credentials_file(path) do
      {:ok, existing} ->
        updated = Map.delete(existing, provider)
        json = Jason.encode!(updated, pretty: true)

        with :ok <- File.write(path, json) do
          File.chmod(path, 0o600)
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the auth status for all known providers.

  Each entry shows whether a key is configured and where it was found
  (`:env`, `:file`, or `nil`). Keys themselves are never exposed.
  """
  @spec status() :: [provider_status()]
  def status do
    Enum.map(@known_providers, fn provider ->
      case resolve(provider) do
        {:ok, _key, source} ->
          %{provider: provider, configured: true, source: source}

        :error ->
          %{provider: provider, configured: false, source: nil}
      end
    end)
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

  # ── Private ─────────────────────────────────────────────────────────────────

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
      {:ok, content} -> Jason.decode(content)
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
