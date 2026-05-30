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
  @fallback_callback_port 1457
  @callback_path "/auth/callback"
  @scopes "openid profile email offline_access"
  @originator "minga"
  @oauth_filename "oauth.json"
  @provider_key "openai-codex"

  @type pkce :: %{verifier: String.t(), challenge: String.t()}

  @type token_response :: %{
          access: String.t(),
          refresh: String.t() | nil,
          expires: integer() | nil,
          account_id: String.t() | nil
        }

  @type openai_config :: %{
          port: pos_integer(),
          fallback_port: pos_integer(),
          authorize_url: String.t(),
          token_url: String.t(),
          client_id: String.t(),
          scopes: String.t(),
          redirect_uri: String.t(),
          callback_path: String.t(),
          originator: String.t()
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
  Builds the full OpenAI authorize URL with Codex CLI-compatible query params.
  """
  @spec openai_authorize_url(String.t(), String.t(), pos_integer()) :: String.t()
  def openai_authorize_url(challenge, state, port \\ @callback_port)
      when is_binary(challenge) and is_binary(state) and is_integer(port) and port > 0 do
    params =
      URI.encode_query([
        {"response_type", "code"},
        {"client_id", @client_id},
        {"redirect_uri", redirect_uri(port)},
        {"scope", @scopes},
        {"code_challenge", challenge},
        {"code_challenge_method", "S256"},
        {"id_token_add_organizations", "true"},
        {"codex_cli_simplified_flow", "true"},
        {"state", state},
        {"originator", @originator}
      ])

    "#{@authorize_url}?#{params}"
  end

  @doc """
  Returns the local redirect URI for an OpenAI OAuth callback port.
  """
  @spec redirect_uri(pos_integer()) :: String.t()
  def redirect_uri(port \\ @callback_port) when is_integer(port) and port > 0 do
    "http://localhost:#{port}#{@callback_path}"
  end

  @doc """
  Returns the static OpenAI OAuth configuration.
  """
  @spec openai_config() :: openai_config()
  def openai_config do
    %{
      port: @callback_port,
      fallback_port: @fallback_callback_port,
      authorize_url: @authorize_url,
      token_url: @token_url,
      client_id: @client_id,
      scopes: @scopes,
      redirect_uri: redirect_uri(),
      callback_path: @callback_path,
      originator: @originator
    }
  end

  @doc """
  Exchanges an authorization code for tokens at the OpenAI token endpoint.

  Returns `{:ok, token_response}` on success or `{:error, reason}` on failure.
  """
  @spec exchange_code(String.t(), String.t(), pos_integer()) ::
          {:ok, token_response()} | {:error, String.t()}
  def exchange_code(code, verifier, port \\ @callback_port)
      when is_binary(code) and is_binary(verifier) and is_integer(port) and port > 0 do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier,
        "client_id" => @client_id,
        "redirect_uri" => redirect_uri(port)
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
      json = :json.format(merged)

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

  @doc "Extracts the ChatGPT account id from an OpenAI OAuth JWT when present."
  @spec account_id_from_token(String.t() | nil) :: String.t() | nil
  def account_id_from_token(nil), do: nil

  def account_id_from_token(jwt) when is_binary(jwt) do
    case decode_jwt_claims(jwt) do
      {:ok, claims} -> account_id_from_claims(claims)
      :error -> nil
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp parse_token_response(resp) do
    access_token = resp["access_token"]
    id_token = resp["id_token"]

    %{
      access: access_token,
      refresh: resp["refresh_token"],
      expires: expires_ms(resp["expires_in"], access_token, id_token),
      account_id: account_id_from_token(access_token) || account_id_from_token(id_token)
    }
  end

  defp expires_ms(expires_in, _access_token, _id_token)
       when is_integer(expires_in) and expires_in > 0 do
    System.system_time(:millisecond) + expires_in * 1000
  end

  defp expires_ms(_expires_in, access_token, id_token) do
    expires_at_from_token(access_token) || expires_at_from_token(id_token)
  end

  defp expires_at_from_token(nil), do: nil

  defp expires_at_from_token(jwt) when is_binary(jwt) do
    with {:ok, claims} <- decode_jwt_claims(jwt),
         exp when is_integer(exp) and exp > 0 <- Map.get(claims, "exp") do
      exp * 1000
    else
      _ -> nil
    end
  end

  defp account_id_from_claims(claims) when is_map(claims) do
    auth_claims = Map.get(claims, "https://api.openai.com/auth")

    account_id_from_auth_claims(auth_claims) ||
      string_field(claims, "chatgpt_account_id") ||
      string_field(claims, "chatgpt-account-id")
  end

  defp account_id_from_auth_claims(claims) when is_map(claims) do
    string_field(claims, "chatgpt_account_id") ||
      string_field(claims, "chatgpt-account-id")
  end

  defp account_id_from_auth_claims(_claims), do: nil

  defp string_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp decode_jwt_claims(jwt) when is_binary(jwt) do
    case String.split(jwt, ".") do
      [_header, payload, _signature] -> decode_jwt_payload(payload)
      _ -> :error
    end
  end

  defp decode_jwt_payload(payload) do
    with {:ok, decoded} <- decode_base64url(payload),
         {:ok, claims} when is_map(claims) <- JSON.decode(decoded) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  defp decode_base64url(payload) do
    case Base.url_decode64(payload, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.url_decode64(payload, padding: true)
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, content} ->
        case JSON.decode(content) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _non_map} -> {:ok, %{}}
          {:error, err} -> {:error, "Failed to parse #{path}: #{inspect(err)}"}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create #{dir}: #{inspect(reason)}"}
    end
  end
end
