defmodule MingaAgent.OAuthTest do
  use ExUnit.Case, async: true

  alias MingaAgent.OAuth

  describe "generate_pkce/0" do
    test "verifier is 43 characters (32 bytes base64url)" do
      %{verifier: verifier} = OAuth.generate_pkce()
      assert byte_size(verifier) == 43
    end

    test "challenge is S256 of verifier" do
      %{verifier: verifier, challenge: challenge} = OAuth.generate_pkce()

      expected =
        :crypto.hash(:sha256, verifier)
        |> Base.url_encode64(padding: false)

      assert challenge == expected
    end

    test "verifier uses only base64url characters without padding" do
      %{verifier: verifier} = OAuth.generate_pkce()
      refute String.contains?(verifier, "=")
      refute String.contains?(verifier, "+")
      refute String.contains?(verifier, "/")
    end

    test "each call produces different values" do
      a = OAuth.generate_pkce()
      b = OAuth.generate_pkce()
      assert a.verifier != b.verifier
    end
  end

  describe "openai_authorize_url/2" do
    test "includes all required OAuth params" do
      url = OAuth.openai_authorize_url("test_challenge", "test_state")
      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert uri.scheme == "https"
      assert uri.host == "auth.openai.com"
      assert uri.path == "/oauth/authorize"
      assert params["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
      assert params["redirect_uri"] == "http://localhost:1455/callback"
      assert params["response_type"] == "code"
      assert params["code_challenge"] == "test_challenge"
      assert params["code_challenge_method"] == "S256"
      assert params["state"] == "test_state"
      assert is_binary(params["scope"])
    end
  end

  describe "openai_config/0" do
    test "returns expected static configuration" do
      config = OAuth.openai_config()
      assert config.port == 1455
      assert config.client_id == "app_EMoamEEZ73f0CkXaXp7hrann"
      assert is_binary(config.authorize_url)
      assert is_binary(config.token_url)
      assert is_binary(config.redirect_uri)
      assert is_binary(config.scopes)
    end
  end

  describe "oauth_file_payload/1" do
    test "structures tokens in ReqLLM schema" do
      tokens = %{
        access: "eyJ_test_access",
        refresh: "oai_rt_test",
        expires: 1_762_857_415_123,
        account_id: "user_123"
      }

      payload = OAuth.oauth_file_payload(tokens)

      assert %{"openai-codex" => entry} = payload
      assert entry["type"] == "oauth"
      assert entry["access"] == "eyJ_test_access"
      assert entry["refresh"] == "oai_rt_test"
      assert entry["expires"] == 1_762_857_415_123
      assert entry["accountId"] == "user_123"
    end

    test "omits nil fields" do
      tokens = %{access: "eyJ_test", refresh: nil, expires: nil, account_id: nil}
      payload = OAuth.oauth_file_payload(tokens)
      entry = payload["openai-codex"]

      assert entry["access"] == "eyJ_test"
      assert entry["type"] == "oauth"
      refute Map.has_key?(entry, "refresh")
      refute Map.has_key?(entry, "expires")
      refute Map.has_key?(entry, "accountId")
    end
  end

  describe "write_oauth_file/2" do
    @tag :tmp_dir
    test "writes oauth.json with 0600 permissions", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "minga", "oauth.json"])

      tokens = %{
        access: "test_access",
        refresh: "test_refresh",
        expires: 999_999,
        account_id: nil
      }

      assert :ok = OAuth.write_oauth_file(tokens, path)
      assert File.exists?(path)

      {:ok, stat} = File.stat(path)
      assert stat.access in [:read_write, :read]

      {:ok, content} = File.read(path)
      {:ok, parsed} = Jason.decode(content)
      assert parsed["openai-codex"]["access"] == "test_access"
      assert parsed["openai-codex"]["refresh"] == "test_refresh"
    end

    @tag :tmp_dir
    test "merges with existing oauth.json content", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "minga", "oauth.json"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"other-provider" => %{"token" => "existing"}}))

      tokens = %{access: "new_access", refresh: nil, expires: nil, account_id: nil}
      assert :ok = OAuth.write_oauth_file(tokens, path)

      {:ok, content} = File.read(path)
      {:ok, parsed} = Jason.decode(content)
      assert parsed["other-provider"]["token"] == "existing"
      assert parsed["openai-codex"]["access"] == "new_access"
    end

    @tag :tmp_dir
    test "creates parent directories if they don't exist", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "dir", "oauth.json"])
      tokens = %{access: "test", refresh: nil, expires: nil, account_id: nil}

      assert :ok = OAuth.write_oauth_file(tokens, path)
      assert File.exists?(path)
    end
  end
end
