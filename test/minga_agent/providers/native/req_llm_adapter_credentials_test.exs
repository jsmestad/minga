defmodule MingaAgent.Providers.Native.ReqLLMAdapterCredentialsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MingaAgent.Credentials
  alias MingaAgent.Providers.Native.ReqLLMAdapter

  @provider_env_vars ~w(ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY OPENROUTER_API_KEY GROQ_API_KEY MISTRAL_API_KEY DEEPSEEK_API_KEY)

  setup do
    nil_env = for var <- @provider_env_vars, into: %{}, do: {var, nil}

    config_home =
      Path.join(
        System.tmp_dir!(),
        "minga_req_llm_adapter_creds_#{System.unique_integer([:positive])}"
      )

    env_sets = :ets.new(:env_sets, [:set, :public])

    opts = [
      config_dir: config_home,
      env: nil_env,
      on_env_set: fn var, val -> :ets.insert(env_sets, {var, val}) end
    ]

    on_exit(fn ->
      File.rm_rf!(config_home)
    end)

    %{config_home: config_home, opts: opts, env_sets: env_sets}
  end

  defp env_set(env_sets, var_name) do
    case :ets.lookup(env_sets, var_name) do
      [{^var_name, val}] -> val
      [] -> nil
    end
  end

  test "file-backed credentials populate the provider env var", %{
    config_home: config_home,
    opts: opts,
    env_sets: env_sets
  } do
    write_credentials(config_home, %{"anthropic" => "file-key"})

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("anthropic:claude", opts)
    assert env_set(env_sets, "ANTHROPIC_API_KEY") == "file-key"
  end

  test "file-backed non-anthropic provider keys populate the matching env var", %{
    config_home: config_home,
    opts: opts,
    env_sets: env_sets
  } do
    write_credentials(config_home, %{"groq" => "groq-file-key"})

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("groq:llama-3.3", opts)
    assert env_set(env_sets, "GROQ_API_KEY") == "groq-file-key"
    assert env_set(env_sets, "ANTHROPIC_API_KEY") == nil
    assert env_set(env_sets, "OPENAI_API_KEY") == nil
  end

  test "file-backed provider keys flow through the credential accessor at call time", %{
    config_home: _config_home,
    opts: opts,
    env_sets: env_sets
  } do
    secret = "sk-ant-fake-bundled-provider"
    assert :ok = Credentials.store("anthropic", secret, opts)
    refute env_set(env_sets, "ANTHROPIC_API_KEY") == secret

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("anthropic:claude-sonnet-4", opts)

    assert env_set(env_sets, "ANTHROPIC_API_KEY") == secret
  end

  test "env-backed credentials keep the existing provider env var", %{
    config_home: config_home,
    opts: opts,
    env_sets: env_sets
  } do
    env_opts = Keyword.update!(opts, :env, &Map.put(&1, "ANTHROPIC_API_KEY", "env-key"))
    write_credentials(config_home, %{"anthropic" => "file-key"})

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("claude@anthropic", env_opts)
    assert env_set(env_sets, "ANTHROPIC_API_KEY") == nil
  end

  test "missing credentials surface actionable auth guidance", %{opts: opts} do
    log =
      capture_log(fn ->
        assert :ok = ReqLLMAdapter.ensure_api_key_in_env("anthropic:claude", opts)
      end)

    assert log =~ "No API key found for anthropic"
    assert log =~ "Use /auth"
    assert log =~ "ANTHROPIC_API_KEY"
  end

  test "invalid model strings do not fall back to anthropic credential lookup", %{
    env_sets: env_sets
  } do
    log =
      capture_log(fn ->
        assert :ok = ReqLLMAdapter.ensure_api_key_in_env("claude")
      end)

    assert log == ""
    assert env_set(env_sets, "ANTHROPIC_API_KEY") == nil
  end

  defp write_credentials(config_home, credentials) do
    dir = Path.join(config_home, "minga")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "credentials.json"), :json.format(credentials))
  end
end
