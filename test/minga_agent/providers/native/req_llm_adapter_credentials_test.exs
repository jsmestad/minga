defmodule MingaAgent.Providers.Native.ReqLLMAdapterCredentialsTest do
  # Not async: these tests mutate process-global System env vars (XDG_CONFIG_HOME and provider API-key vars).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MingaAgent.Providers.Native.ReqLLMAdapter

  setup do
    previous_xdg = System.get_env("XDG_CONFIG_HOME")
    previous_anthropic = System.get_env("ANTHROPIC_API_KEY")

    config_home =
      Path.join(
        System.tmp_dir!(),
        "minga_req_llm_adapter_creds_#{System.unique_integer([:positive])}"
      )

    System.put_env("XDG_CONFIG_HOME", config_home)
    System.delete_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      restore_env("XDG_CONFIG_HOME", previous_xdg)
      restore_env("ANTHROPIC_API_KEY", previous_anthropic)
      File.rm_rf!(config_home)
    end)

    %{config_home: config_home}
  end

  test "file-backed credentials populate the provider env var", %{config_home: config_home} do
    write_credentials(config_home, %{"anthropic" => "file-key"})

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("anthropic:claude")
    assert System.get_env("ANTHROPIC_API_KEY") == "file-key"
  end

  test "env-backed credentials keep the existing provider env var", %{config_home: config_home} do
    System.put_env("ANTHROPIC_API_KEY", "env-key")
    write_credentials(config_home, %{"anthropic" => "file-key"})

    assert :ok = ReqLLMAdapter.ensure_api_key_in_env("claude@anthropic")
    assert System.get_env("ANTHROPIC_API_KEY") == "env-key"
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
    assert System.get_env("ANTHROPIC_API_KEY") == nil
  end

  defp write_credentials(config_home, credentials) do
    dir = Path.join(config_home, "minga")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "credentials.json"), :json.format(credentials))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
