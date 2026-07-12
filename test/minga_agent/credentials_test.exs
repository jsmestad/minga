defmodule MingaAgent.CredentialsTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials

  @test_dir "test/tmp/credentials_test"

  @nil_env %{
    "ANTHROPIC_API_KEY" => nil,
    "OPENAI_API_KEY" => nil,
    "GOOGLE_API_KEY" => nil,
    "OPENROUTER_API_KEY" => nil,
    "GROQ_API_KEY" => nil,
    "MISTRAL_API_KEY" => nil,
    "DEEPSEEK_API_KEY" => nil
  }

  setup do
    dir = Path.join(@test_dir, "#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    parent_dir = Path.join(dir, "config")
    File.mkdir_p!(Path.join(parent_dir, "minga"))

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    opts = [
      config_dir: parent_dir,
      env: @nil_env,
      oauth_probe: fn -> false end,
      ollama_probe: fn -> false end
    ]

    %{
      dir: dir,
      config_dir: parent_dir,
      creds_path: Path.join([parent_dir, "minga", "credentials.json"]),
      opts: opts
    }
  end

  describe "store/3 and resolve/2" do
    test "stores and resolves a key from file", %{creds_path: creds_path, opts: opts} do
      assert :ok = Credentials.store("anthropic", "sk-ant-test-123", opts)
      assert {:ok, "sk-ant-test-123", :file} = Credentials.resolve("anthropic", opts)

      {:ok, stat} = File.stat(creds_path)
      assert stat.access == :read_write
    end

    test "env var takes precedence over file", %{opts: opts} do
      env_opts = Keyword.put(opts, :env, Map.put(@nil_env, "ANTHROPIC_API_KEY", "env-key-123"))

      :ok = Credentials.store("anthropic", "file-key-456", opts)
      assert {:ok, "env-key-123", :env} = Credentials.resolve("anthropic", env_opts)
    end

    test "returns :error when no key is configured", %{opts: opts} do
      assert :error = Credentials.resolve("anthropic", opts)
    end

    test "stores keys for multiple providers", %{opts: opts} do
      :ok = Credentials.store("anthropic", "ant-key", opts)
      :ok = Credentials.store("openai", "oai-key", opts)

      assert {:ok, "ant-key", :file} = Credentials.resolve("anthropic", opts)
      assert {:ok, "oai-key", :file} = Credentials.resolve("openai", opts)
    end

    test "overwrites existing key on re-store", %{opts: opts} do
      :ok = Credentials.store("anthropic", "old-key", opts)
      :ok = Credentials.store("anthropic", "new-key", opts)

      assert {:ok, "new-key", :file} = Credentials.resolve("anthropic", opts)
    end
  end

  describe "revoke/2" do
    test "removes a stored key", %{opts: opts} do
      :ok = Credentials.store("anthropic", "sk-ant-test", opts)
      assert {:ok, _, :file} = Credentials.resolve("anthropic", opts)

      :ok = Credentials.revoke("anthropic", opts)
      assert :error = Credentials.resolve("anthropic", opts)
    end

    test "revoke is a no-op when no file exists", %{opts: opts} do
      assert :ok = Credentials.revoke("anthropic", opts)
    end

    test "revoke preserves other providers", %{opts: opts} do
      :ok = Credentials.store("anthropic", "ant-key", opts)
      :ok = Credentials.store("openai", "oai-key", opts)

      :ok = Credentials.revoke("anthropic", opts)
      assert :error = Credentials.resolve("anthropic", opts)
      assert {:ok, "oai-key", :file} = Credentials.resolve("openai", opts)
    end
  end

  describe "status/1" do
    test "reports unconfigured when nothing is set", %{opts: opts} do
      statuses = Credentials.status(opts)
      assert Enum.count(statuses) == 9
    end

    test "reports configured with correct source", %{opts: opts} do
      :ok = Credentials.store("anthropic", "ant-key", opts)

      env_opts = Keyword.put(opts, :env, Map.put(@nil_env, "OPENAI_API_KEY", "oai-env-key"))

      statuses = Credentials.status(env_opts)
      ant = Enum.find(statuses, &(&1.provider == "anthropic"))
      oai = Enum.find(statuses, &(&1.provider == "openai"))
      ggl = Enum.find(statuses, &(&1.provider == "google"))

      assert ant.configured == true
      assert ant.source == :file
      assert oai.configured == true
      assert oai.source == :env
      assert ggl.configured == false
    end
  end

  describe "any_configured?/0" do
    test "returns false when nothing is configured", %{opts: opts} do
      refute Credentials.any_configured?(opts)
    end

    test "returns true when at least one key exists", %{opts: opts} do
      :ok = Credentials.store("anthropic", "some-key", opts)
      assert Credentials.any_configured?(opts)
    end
  end

  describe "provider_from_model/1" do
    test "extracts provider from prefixed model string" do
      assert "anthropic" = Credentials.provider_from_model("anthropic:claude-sonnet-4-20250514")
      assert "openai" = Credentials.provider_from_model("openai:gpt-4o")
      assert "google" = Credentials.provider_from_model("google:gemini-pro")
    end

    test "defaults to anthropic for bare model names" do
      assert "anthropic" = Credentials.provider_from_model("claude-sonnet-4-20250514")
    end
  end

  describe "env_var_for/1" do
    test "returns correct env var names" do
      assert "ANTHROPIC_API_KEY" = Credentials.env_var_for("anthropic")
      assert "OPENAI_API_KEY" = Credentials.env_var_for("openai")
      assert "GOOGLE_API_KEY" = Credentials.env_var_for("google")
    end

    test "returns nil for unknown provider" do
      assert nil == Credentials.env_var_for("unknown")
    end
  end
end
