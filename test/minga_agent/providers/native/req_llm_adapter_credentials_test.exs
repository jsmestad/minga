defmodule MingaAgent.Providers.Native.ReqLLMAdapterCredentialsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MingaAgent.Credentials
  alias MingaAgent.Providers.Native.ReqLLMAdapter

  @provider_env_vars ~w(ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY OPENROUTER_API_KEY GROQ_API_KEY MISTRAL_API_KEY DEEPSEEK_API_KEY)

  setup do
    nil_overrides = for var <- @provider_env_vars, into: %{}, do: {var, nil}
    Process.put(:minga_env_overrides, nil_overrides)

    config_home =
      Path.join(
        System.tmp_dir!(),
        "minga_req_llm_adapter_creds_#{System.unique_integer([:positive])}"
      )

    Process.put(:minga_config_home, config_home)

    on_exit(fn ->
      Process.delete(:minga_env_overrides)
      Process.delete(:minga_config_home)
      File.rm_rf!(config_home)
    end)

    %{config_home: config_home}
  end

  defp env_override(var_name) do
    case Process.get(:minga_env_overrides) do
      %{^var_name => val} -> val
      _ -> nil
    end
  end

  test "file-backed credentials populate the provider env var", %{config_home: config_home} do
    write_credentials(config_home, %{"anthropic" => "file-key"})

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("anthropic:claude")
    assert env_override("ANTHROPIC_API_KEY") == "file-key"
  end

  test "file-backed non-anthropic provider keys populate the matching env var", %{
    config_home: config_home
  } do
    write_credentials(config_home, %{"groq" => "groq-file-key"})

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("groq:llama-3.3")
    assert env_override("GROQ_API_KEY") == "groq-file-key"
    assert env_override("ANTHROPIC_API_KEY") == nil
    assert env_override("OPENAI_API_KEY") == nil
  end

  test "file-backed provider keys flow through the credential accessor at call time" do
    secret = "sk-ant-fake-bundled-provider"
    assert :ok = Credentials.store("anthropic", secret)
    refute env_override("ANTHROPIC_API_KEY") == secret

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("anthropic:claude-sonnet-4")

    assert env_override("ANTHROPIC_API_KEY") == secret
  end

  test "env-backed credentials keep the existing provider env var", %{config_home: config_home} do
    overrides = Process.get(:minga_env_overrides)
    Process.put(:minga_env_overrides, Map.put(overrides, "ANTHROPIC_API_KEY", "env-key"))
    write_credentials(config_home, %{"anthropic" => "file-key"})

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("claude@anthropic")
    assert env_override("ANTHROPIC_API_KEY") == "env-key"
  end

  test "missing credentials surface actionable auth guidance" do
    log =
      capture_log(fn ->
        assert :ok = ReqLLMAdapter.ensure_api_key_in_env("anthropic:claude")
      end)

    assert log =~ "No API key found for anthropic"
    assert log =~ "Use /auth"
    assert log =~ "ANTHROPIC_API_KEY"
  end

  test "invalid model strings do not fall back to anthropic credential lookup" do
    log =
      capture_log(fn ->
        assert :ok = ReqLLMAdapter.ensure_api_key_in_env("claude")
      end)

    assert log == ""
    assert env_override("ANTHROPIC_API_KEY") == nil
  end

  defp write_credentials(config_home, credentials) do
    dir = Path.join(config_home, "minga")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "credentials.json"), :json.format(credentials))
  end
end
