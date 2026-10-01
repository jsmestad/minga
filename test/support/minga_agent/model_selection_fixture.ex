defmodule MingaAgent.Test.ModelSelectionFixture do
  @moduledoc false

  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.ApiKey
  alias MingaAgent.ModelSelection.Credential.None
  alias MingaAgent.ModelSelection.Evidence
  alias MingaAgent.ModelSelection.Policy
  alias MingaAgent.ModelSelection.Route
  alias MingaAgent.ModelSelection.TextExecution
  alias MingaAgent.Provider.Spec
  alias MingaAgent.Providers.Native
  @custom_model_id "test-model"

  @spec config(MingaAgent.Config.t()) :: MingaAgent.Config.t()
  def config(config \\ %MingaAgent.Config{}) do
    endpoint = %{
      "url" => "http://127.0.0.1:1/v1",
      "protocol" => "openai_chat",
      "auth_mode" => "none",
      "models" => %{
        @custom_model_id => %{
          "name" => "Test Model",
          "reasoning_options" => ["off", "none", "minimal", "low", "medium", "high"]
        }
      }
    }

    endpoints = Map.put(config.api_endpoints || %{}, "test", endpoint)
    %{config | api_endpoints: endpoints}
  end

  @spec model_intent() :: String.t()
  def model_intent, do: "test:#{@custom_model_id}"

  @spec selection(keyword()) :: ModelSelection.t()
  def selection(opts \\ []) do
    request_provider = Keyword.get(opts, :request_provider, :openai)
    defaults = execution_defaults(request_provider)
    model_id = Keyword.get(opts, :model_id, "test-model")
    model_provider = Keyword.get(opts, :model_provider, Atom.to_string(request_provider))
    display_name = Keyword.get(opts, :display_name, model_id)

    {:ok, execution} =
      TextExecution.new(%{
        supported: true,
        family: Keyword.get(opts, :family, defaults.family),
        wire_protocol: Keyword.get(opts, :wire_protocol, defaults.wire_protocol),
        transport: Keyword.get(opts, :transport, defaults.transport),
        provider_model_id: Keyword.get(opts, :provider_model_id, model_id),
        base_url: Keyword.get(opts, :base_url, defaults.base_url),
        path: Keyword.get(opts, :path, defaults.path)
      })

    {:ok, route} =
      Route.new(%{
        origin: Keyword.get(opts, :origin, {:custom, "test", model_id}),
        request_provider: request_provider,
        id: Keyword.get(opts, :route_id, "test/#{model_id}"),
        model_provider: model_provider,
        model_id: model_id,
        display_name: display_name,
        execution: execution,
        metadata: %{}
      })

    {:ok, policy} =
      Policy.new(%{
        reasoning:
          Keyword.get(opts, :reasoning, %{
            effort: "off",
            options: ["off", "none", "minimal", "low", "medium", "high", "xhigh", "max"]
          }),
        limits:
          Keyword.get(opts, :limits, %{
            context: 200_000,
            input: nil,
            output: 8_192,
            request_output: 8_192
          }),
        capabilities:
          Keyword.get(opts, :capabilities, %{tools: true, images: true, streaming: true}),
        cost: %{}
      })

    {:ok, selection} =
      ModelSelection.build(
        Spec.new!(source: :config, id: "native", module: Native, display_name: "Native"),
        route,
        Keyword.get_lazy(opts, :credential, fn -> fixture_credential(request_provider) end),
        policy,
        Evidence.new(
          Keyword.get(opts, :catalog_evidence, false),
          Keyword.get(opts, :custom_evidence, true)
        )
      )

    selection
  end

  @spec fixture_credential(atom()) :: ModelSelection.credential_ref()
  defp fixture_credential(:openai), do: None.new("test")
  defp fixture_credential(provider), do: ApiKey.new(Atom.to_string(provider), :env)

  @spec execution_defaults(atom()) :: map()
  defp execution_defaults(:anthropic) do
    %{
      family: "anthropic_messages",
      wire_protocol: "anthropic_messages",
      transport: "http",
      base_url: "https://anthropic.example/v1",
      path: "/v1/messages"
    }
  end

  defp execution_defaults(:openai) do
    %{
      family: "openai_chat_compatible",
      wire_protocol: "openai_chat",
      transport: "http",
      base_url: "http://127.0.0.1:1/v1",
      path: "/chat/completions"
    }
  end
end
