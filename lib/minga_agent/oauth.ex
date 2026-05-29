defmodule MingaAgent.OAuth do
  @moduledoc """
  OpenAI OAuth acquisition helpers: PKCE generation, authorize URL
  construction, code exchange, and oauth.json persistence.

  Pure calculations with no processes. The flow orchestration lives in
  `MingaAgent.OAuth.Flow`.
  """

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @authorize_url "https://auth.openai.com/oauth/authorize"
  @token_url "https://auth.openai.com/oauth/token"
  @callback_port 1455
  @redirect_uri "http://localhost:#{@callback_port}/callback"
  @scopes "openid offline_access"
  @oauth_filename "oauth.json"
  @provider_key "openai-codex"

  @type pkce :: %{verifier: String.t(), challenge: String.t()}

  @type token_response :: %{
          access: String.t(),
          refresh: String.t() | nil,
          expires: integer() | nil,
          account_id: String.t() | nil
        }

  @doc """
  Generates a PKCE verifier and S256 challenge per RFC 7636.

  The verifier is 32 random bytes, base64url-encoded without padding (43 chars).
  The challenge is the SHA-256 hash of the verifier, base64url-encoded.
  """
  @spec generate_pkce() :: pkce()
  def generate_pkce do
    verifier =
      :crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    %{verifier: verifier, challenge: challenge}
  end

  @doc """
  Builds the full OpenAI authorize URL with all required query params.
  """
  @spec openai_authorize_url(String.t(), String.t()) :: String.t()
  def openai_authorize_url(challenge, state) do
    params =
      URI.encode_query(%{
        "client_id" => @client_id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "scope" => @scopes,
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    "#{@authorize_url}?#{params}"
  end

  @doc """
  Returns the static OpenAI OAuth configuration.
  """
  @spec openai_config() :: map()
  def openai_config do
    %{
      port: @callback_port,
      authorize_url: @authorize_url,
      token_url: @token_url,
      client_id: @client_id,
      scopes: @scopes,
      redirect_uri: @redirect_uri
    }
  end

  @doc """
  Exchanges an authorization code for tokens at the OpenAI token endpoint.

  Returns `{:ok, token_response}` on success or `{:error, reason}` on failure.
  """
  @spec exchange_code(String.t(), String.t()) :: {:ok, token_response()} | {:error, String.t()}
  def exchange_code(code, verifier) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier,
        "client_id" => @client_id,
        "redirect_uri" => @redirect_uri
      })

    case Req.post(@token_url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: 200, body: resp}} when is_map(resp) ->
        case parse_token_response(resp) do
          %{access: access} = tokens when is_binary(access) and access != "" ->
            {:ok, tokens}

          _ ->
            {:error, "Token exchange succeeded but response did not contain an access token"}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        detail =
          if is_map(body),
            do: Map.get(body, "error_description", inspect(body)),
            else: inspect(body)

        {:error, "Token exchange failed (HTTP #{status}): #{detail}"}

      {:error, exception} ->
        {:error, "Token exchange request failed: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Builds the `oauth.json` map payload in ReqLLM's expected schema.
  """
  @spec oauth_file_payload(token_response()) :: map()
  def oauth_file_payload(tokens) do
    entry =
      %{
        "type" => "oauth",
        "access" => tokens.access,
        "refresh" => tokens.refresh,
        "expires" => tokens.expires,
        "accountId" => tokens.account_id
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    %{@provider_key => entry}
  end

  @doc """
  Writes tokens to the oauth.json file with 0600 permissions.

  Merges into any existing file content so other provider entries are preserved.
  """
  @spec write_oauth_file(token_response(), String.t()) :: :ok | {:error, String.t()}
  def write_oauth_file(tokens, path \\ oauth_path()) do
    dir = Path.dirname(path)

    with :ok <- ensure_dir(dir),
         {:ok, existing} <- read_existing(path) do
      merged = Map.merge(existing, oauth_file_payload(tokens))
      json = Jason.encode!(merged, pretty: true)

      case File.write(path, json) do
        :ok ->
          File.chmod(path, 0o600)
          :ok

        {:error, reason} ->
          {:error, "Failed to write #{path}: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Returns the path to `~/.config/minga/oauth.json` (XDG-aware).
  """
  @spec oauth_path() :: String.t()
  def oauth_path do
    config_dir = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([config_dir, "minga", @oauth_filename])
  end

  @doc "The provider key used in oauth.json."
  @spec provider_key() :: String.t()
  def provider_key, do: @provider_key

  # ── Private ──────────────────────────────────────────────────────────────────

  defp parse_token_response(resp) do
    expires_in = resp["expires_in"]

    expires_ms =
      if is_integer(expires_in) and expires_in > 0 do
        System.system_time(:millisecond) + expires_in * 1000
      end

    %{
      access: resp["access_token"],
      refresh: resp["refresh_token"],
      expires: expires_ms,
      account_id: extract_account_id(resp["access_token"])
    }
  end

  defp extract_account_id(nil), do: nil

  defp extract_account_id(jwt) when is_binary(jwt) do
    case String.split(jwt, ".") do
      [_header, payload, _sig | _] ->
        with {:ok, decoded} <- Base.url_decode64(payload, padding: false),
             {:ok, claims} <- Jason.decode(decoded) do
          claims["https://api.openai.com/auth"]["user_id"] ||
            claims["chatgpt-account-id"] ||
            claims["sub"]
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, ""} -> {:ok, %{}}
      {:ok, content} -> Jason.decode(content)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create #{dir}: #{inspect(reason)}"}
    end
  end
end
