defmodule MingaAgent.Test.ModelSelectionFixture do
  @moduledoc false

  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.ApiKey
  alias MingaAgent.ModelSelection.Evidence
  alias MingaAgent.ModelSelection.Policy
  alias MingaAgent.ModelSelection.Route
  alias MingaAgent.ModelSelection.TextExecution
  alias MingaAgent.Provider.Spec
  alias MingaAgent.ProviderPacks.Native, as: NativeProviderPack
  alias MingaAgent.Providers.Native
  @model_id "test-model"

  @spec model_intent() :: String.t()
  def model_intent, do: "openai:#{@model_id}"

  @spec resolver_opts(keyword()) :: keyword()
  def resolver_opts(opts \\ []) do
    model_id = Keyword.get(opts, :model_id, @model_id)
    provider_model_id = Keyword.get(opts, :provider_model_id, model_id)
    base_url = Keyword.get(opts, :base_url, "https://api.openai.example/v1")

    model = %{
      id: "openai/#{model_id}",
      provider: :openai,
      name: Keyword.get(opts, :display_name, "Test Model"),
      provider_model_id: provider_model_id,
      aliases: [],
      deprecated: false,
      retired: false,
      catalog_only: false,
      modalities: %{"input" => ["text"], "output" => ["text", "image"]},
      capabilities: %{
        "tools" => %{"enabled" => true},
        "streaming" => %{"text" => true}
      },
      limits: %{"context" => 200_000, "input" => nil, "output" => 8_192},
      execution: %{
        text: %{
          supported: true,
          family: "openai_chat_compatible",
          wire_protocol: "openai_chat",
          transport: "http",
          provider_model_id: provider_model_id,
          base_url: base_url,
          path: "/chat/completions"
        }
      },
      extra: %{
        "reasoning_options" => ["off", "none", "minimal", "low", "medium", "high"]
      },
      cost: %{}
    }

    [
      backend_spec: NativeProviderPack.spec(),
      credential_snapshot: Snapshot.new(%{"openai" => :env}, nil),
      models: [model],
      providers: [%{id: :openai, runtime: %{"base_url" => base_url}}]
    ]
  end

  @spec selection(keyword()) :: ModelSelection.t()
  def selection(opts \\ []) do
    request_provider = Keyword.get(opts, :request_provider, :openai)
    defaults = execution_defaults(request_provider)
    model_id = Keyword.get(opts, :model_id, "test-model")

    default_owner =
      if request_provider == :openai_codex, do: "openai", else: Atom.to_string(request_provider)

    model_provider = Keyword.get(opts, :model_provider, default_owner)
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
        origin:
          Keyword.get(
            opts,
            :origin,
            {:catalog, model_provider, model_id}
          ),
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
          opts
          |> Keyword.get(:capabilities, %{tools: true, images: true, streaming: true})
          |> Map.put_new(:tool_result_images, :unknown),
        cost: %{}
      })

    {:ok, selection} =
      ModelSelection.build(
        Spec.new!(source: :config, id: "native", module: Native, display_name: "Native"),
        route,
        Keyword.get_lazy(opts, :credential, fn ->
          fixture_credential(request_provider, model_provider)
        end),
        policy,
        Evidence.new()
      )

    selection
  end

  @spec fixture_credential(atom(), String.t()) :: ModelSelection.credential_ref()
  defp fixture_credential(:openai_codex, _owner),
    do:
      MingaAgent.ModelSelection.Credential.OAuth.new("fixture-account", "/tmp/fixture-oauth.json")

  defp fixture_credential(_provider, owner), do: ApiKey.new(owner, :env)

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

  defp execution_defaults(:openai_codex) do
    %{
      family: "openai_responses_compatible",
      wire_protocol: "openai_codex_responses",
      transport: "http",
      base_url: "https://chatgpt.com/backend-api",
      path: "/codex/responses"
    }
  end

  defp execution_defaults(:google) do
    %{
      family: "google_generate_content",
      wire_protocol: "google_generate_content",
      transport: "http",
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      path: "/models/{provider_model_id}:generateContent"
    }
  end

  defp execution_defaults(:openai) do
    %{
      family: "openai_chat_compatible",
      wire_protocol: "openai_chat",
      transport: "http",
      base_url: "https://api.openai.example/v1",
      path: "/chat/completions"
    }
  end
end
