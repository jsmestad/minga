defmodule MingaAgent.Providers.Native.ReqLLMAdapterCredentialsTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config
  alias MingaAgent.Credentials
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelResolver
  alias MingaAgent.ProviderPacks.Native
  alias MingaAgent.Providers.Native.ReqLLMAdapter

  setup do
    config_dir =
      Path.join(
        System.tmp_dir!(),
        "minga_request_credentials_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(config_dir) end)
    %{opts: [config_dir: config_dir, env: %{"ANTHROPIC_API_KEY" => nil}]}
  end

  test "request uses its selected file profile even when an environment key coexists", %{
    opts: opts
  } do
    assert :ok = Credentials.store("anthropic", "file-key", opts)
    selection = selection(:file)
    opts = Keyword.put(opts, :env, %{"ANTHROPIC_API_KEY" => "different-env-key"})
    assert {:ok, request} = ReqLLMAdapter.stream_opts(selection, [], %Config{}, opts)
    assert request[:api_key] == "file-key"
    assert request[:auth_mode] == :api_key
  end

  test "revoked selected file profile cannot fall back to a coexisting environment key", %{
    opts: opts
  } do
    selection = selection(:file)
    opts = Keyword.put(opts, :env, %{"ANTHROPIC_API_KEY" => "other-account"})

    assert {:error, {:credential_unavailable, "anthropic:file"}} =
             ReqLLMAdapter.stream_opts(selection, [], %Config{}, opts)
  end

  test "missing selected environment profile cannot fall back to a stored key", %{opts: opts} do
    assert :ok = Credentials.store("anthropic", "other-account", opts)

    assert {:error, {:credential_unavailable, "anthropic:env"}} =
             ReqLLMAdapter.stream_opts(selection(:env), [], %Config{}, opts)
  end

  defp selection(source) do
    model = %{
      id: "fixture",
      provider: :anthropic,
      provider_model_id: "fixture",
      modalities: %{input: [:text], output: [:text]},
      capabilities: %{tools: %{enabled: true}, streaming: %{text: true}},
      execution: %{
        text: %{
          supported: true,
          family: "anthropic_messages",
          wire_protocol: "anthropic_messages",
          transport: "http",
          provider_model_id: "fixture",
          base_url: "https://anthropic.example/v1",
          path: "/v1/messages"
        }
      }
    }

    {:ok, selection} =
      ModelResolver.resolve("anthropic:fixture",
        backend_spec: Native.spec(),
        credential_snapshot: Snapshot.new(%{"anthropic" => source}, nil, "http://localhost"),
        models: [model],
        providers: [
          %{id: :anthropic, runtime: %{base_url: "https://anthropic.example/v1"}}
        ]
      )

    selection
  end
end
