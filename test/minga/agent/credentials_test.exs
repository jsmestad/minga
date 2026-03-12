defmodule Minga.Agent.CredentialsTest do
  use ExUnit.Case, async: false

  alias Minga.Agent.Credentials

  @test_dir "test/tmp/credentials_test"

  setup do
    # Use a unique temp dir per test to avoid interference
    dir = Path.join(@test_dir, "#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    # Override XDG_CONFIG_HOME so credentials_path() points to our temp dir
    # We need to set the parent of "minga/" since credentials_path joins "minga"
    parent_dir = Path.join(dir, "config")
    File.mkdir_p!(Path.join(parent_dir, "minga"))
    System.put_env("XDG_CONFIG_HOME", parent_dir)

    on_exit(fn ->
      System.delete_env("XDG_CONFIG_HOME")
      File.rm_rf!(dir)
    end)

    %{
      dir: dir,
      config_dir: parent_dir,
      creds_path: Path.join([parent_dir, "minga", "credentials.json"])
    }
  end

  describe "store/2 and resolve/1" do
    test "stores and resolves a key from file", %{creds_path: creds_path} do
      assert :ok = Credentials.store("anthropic", "sk-ant-test-123")
      assert {:ok, "sk-ant-test-123", :file} = Credentials.resolve("anthropic")

      # Verify file permissions
      {:ok, stat} = File.stat(creds_path)
      assert stat.access == :read_write
    end

    test "env var takes precedence over file" do
      System.put_env("ANTHROPIC_API_KEY", "env-key-123")

      on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)

      :ok = Credentials.store("anthropic", "file-key-456")
      assert {:ok, "env-key-123", :env} = Credentials.resolve("anthropic")
    end

    test "returns :error when no key is configured" do
      # Make sure env var is not set
      System.delete_env("ANTHROPIC_API_KEY")
      assert :error = Credentials.resolve("anthropic")
    end

    test "stores keys for multiple providers" do
      :ok = Credentials.store("anthropic", "ant-key")
      :ok = Credentials.store("openai", "oai-key")

      assert {:ok, "ant-key", :file} = Credentials.resolve("anthropic")
      assert {:ok, "oai-key", :file} = Credentials.resolve("openai")
    end

    test "overwrites existing key on re-store" do
      :ok = Credentials.store("anthropic", "old-key")
      :ok = Credentials.store("anthropic", "new-key")

      assert {:ok, "new-key", :file} = Credentials.resolve("anthropic")
    end
  end

  describe "revoke/1" do
    test "removes a stored key" do
      System.delete_env("ANTHROPIC_API_KEY")
      :ok = Credentials.store("anthropic", "sk-ant-test")
      assert {:ok, _, :file} = Credentials.resolve("anthropic")

      :ok = Credentials.revoke("anthropic")
      assert :error = Credentials.resolve("anthropic")
    end

    test "revoke is a no-op when no file exists" do
      assert :ok = Credentials.revoke("anthropic")
    end

    test "revoke preserves other providers" do
      System.delete_env("OPENAI_API_KEY")
      :ok = Credentials.store("anthropic", "ant-key")
      :ok = Credentials.store("openai", "oai-key")

      :ok = Credentials.revoke("anthropic")
      assert :error = Credentials.resolve("anthropic")
      assert {:ok, "oai-key", :file} = Credentials.resolve("openai")
    end
  end

  describe "status/0" do
    test "reports unconfigured when nothing is set" do
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")

      statuses = Credentials.status()
      assert length(statuses) == 3
      assert Enum.all?(statuses, fn s -> s.configured == false end)
    end

    test "reports configured with correct source" do
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")

      :ok = Credentials.store("anthropic", "ant-key")
      System.put_env("OPENAI_API_KEY", "oai-env-key")

      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      statuses = Credentials.status()
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
    test "returns false when nothing is configured" do
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")

      refute Credentials.any_configured?()
    end

    test "returns true when at least one key exists" do
      :ok = Credentials.store("anthropic", "some-key")
      assert Credentials.any_configured?()
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
