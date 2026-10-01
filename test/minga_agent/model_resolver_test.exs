defmodule MingaAgent.ModelResolverTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelSelection
  alias MingaAgent.ProviderPacks.Native

  @provider %{
    id: :openai,
    runtime: %{"base_url" => "https://api.openai.example/v1"}
  }

  @catalog_model %{
    id: "openai/not-a-codex-name",
    provider: :openai,
    name: "Exact Catalog Model",
    provider_model_id: "not-a-codex-name",
    aliases: [],
    deprecated: false,
    retired: false,
    catalog_only: false,
    modalities: %{"input" => ["text"], "output" => ["text"]},
    capabilities: %{
      "tools" => %{"enabled" => true},
      "streaming" => %{"text" => true}
    },
    limits: %{"context" => 32_000, "input" => 30_000, "output" => 2_000},
    execution: %{
      text: %{
        supported: true,
        family: "openai_responses_compatible",
        wire_protocol: "openai_responses",
        transport: "http",
        provider_model_id: "not-a-codex-name",
        base_url: "https://api.openai.example/v1",
        path: "/responses"
      }
    },
    extra: %{
      "wire" => %{"protocol" => "openai_responses"},
      "reasoning_options" => ["low", "high"]
    },
    cost: %{}
  }

  test "keeps catalog routes unverified without exact model evidence" do
    assert {:ok, selection} =
             ModelResolver.resolve(
               %{"model" => "openai:not-a-codex-name", "reasoning_effort" => "high"},
               resolver_opts(Snapshot.new(%{"openai" => :env}, nil, "http://localhost"))
             )

    assert selection.route.execution.wire_protocol == "openai_responses"
    assert selection.route.execution.base_url == "https://api.openai.example/v1"
    assert ModelSelection.credential_id(selection.credential) == "openai:env"
    assert selection.policy.reasoning.effort == "high"
    assert selection.policy.limits.context == 32_000
    assert selection.policy.limits.output == 2_000
    assert selection.policy.limits.request_output == 2_000
    assert selection.policy.capabilities.tools == true
    assert selection.policy.capabilities.images == false
    assert selection.evidence.status == :unverified
  end

  test "resolves models returned as catalog structs without enumerating them" do
    {:ok, model} =
      LLMDB.Model.new(%{
        @catalog_model
        | modalities: %{input: [:text], output: [:text]},
          capabilities: %{tools: %{enabled: true}, streaming: %{text: true}},
          limits: %{context: 32_000, input: 30_000, output: 2_000}
      })

    opts =
      Snapshot.new(%{"openai" => :env}, nil, "http://localhost")
      |> resolver_opts()
      |> Keyword.put(:models, [model])

    assert {:ok, selection} = ModelResolver.resolve("openai:not-a-codex-name", opts)
    assert selection.route.execution.provider_model_id == "not-a-codex-name"
    assert selection.policy.limits.context == 32_000
    assert selection.policy.capabilities.tools == true
  end

  test "freezes inherited HTTP transport and a catalog model's exact default wire ID" do
    model = %{
      @catalog_model
      | id: "opaque/model:raw",
        provider_model_id: nil,
        execution: %{
          text: %{
            @catalog_model.execution.text
            | transport: nil,
              provider_model_id: nil,
              base_url: nil
          }
        }
    }

    opts =
      Snapshot.new(%{"openai" => :env}, nil, "http://localhost")
      |> resolver_opts()
      |> Keyword.put(:models, [model])

    assert {:ok, selection} = ModelResolver.resolve("openai:opaque/model:raw", opts)
    assert selection.route.execution.transport == "http"
    assert selection.route.execution.provider_model_id == "opaque/model:raw"
    assert selection.route.execution.base_url == "https://api.openai.example/v1"

    unsupported = put_in(model.execution.text.transport, "grpc")

    assert {:error, _reason} =
             ModelResolver.resolve(
               "openai:opaque/model:raw",
               Keyword.put(opts, :models, [unsupported])
             )
  end

  test "restoration refuses to switch to another credential source" do
    {:ok, selection} =
      ModelResolver.resolve(
        "openai:not-a-codex-name",
        resolver_opts(Snapshot.new(%{"openai" => :env}, nil, "http://localhost"))
      )

    assert {:error, {:selection_correction_required, message}} =
             ModelResolver.restore(
               selection,
               resolver_opts(Snapshot.new(%{"openai" => :file}, nil, "http://localhost"))
             )

    assert message =~ "openai:env"
    refute message =~ "API key"
  end

  test "custom routes retain conservative unknown capabilities and exact explicit endpoint" do
    config = %Config{
      max_tokens: 1_024,
      api_endpoints: %{
        "local" => %{
          "url" => "http://127.0.0.1:9000/v1",
          "protocol" => "openai_chat",
          "auth_mode" => "none",
          "models" => %{
            "private-model" => %{
              "name" => "Private Model",
              "protocol" => "openai_chat",
              "limits" => %{}
            }
          }
        }
      }
    }

    assert {:ok, selection} =
             ModelResolver.resolve(
               "local:private-model",
               resolver_opts(Snapshot.new(%{}, nil, "http://localhost"), config)
             )

    assert selection.route.execution.base_url == "http://127.0.0.1:9000/v1"
    assert ModelSelection.credential_id(selection.credential) == "local:none"
    assert selection.policy.limits.context == nil
    assert selection.policy.limits.input == nil
    assert selection.policy.limits.output == nil
    assert selection.policy.capabilities.tools == :unknown
    assert selection.policy.capabilities.images == :unknown
    assert selection.policy.capabilities.streaming == :unknown
    assert selection.evidence.status == :unverified
  end

  test "serialized identity is versioned and contains no credential value" do
    {:ok, selection} =
      ModelResolver.resolve(
        "openai:not-a-codex-name",
        resolver_opts(Snapshot.new(%{"openai" => :env}, nil, "http://localhost"))
      )

    encoded = ModelSelection.encode(selection)

    assert encoded["version"] == ModelSelection.version()

    assert encoded["credential"] == %{
             "kind" => "api_key",
             "provider" => "openai",
             "source" => "env"
           }

    refute Map.has_key?(encoded, "api_key")
    refute Map.has_key?(encoded, "access_token")
    assert {:ok, stored} = ModelSelection.decode(encoded)
    assert ModelSelection.id(stored) == ModelSelection.id(selection)
  end

  test "JSON restoration preserves unknown limits and explicitly unsupported tools" do
    model = %{
      @catalog_model
      | limits: %{context: nil, input: nil, output: nil},
        capabilities: %{tools: %{enabled: false}, streaming: %{text: true}}
    }

    opts =
      Snapshot.new(%{"openai" => :env}, nil, "http://localhost")
      |> resolver_opts()
      |> Keyword.put(:models, [model])

    {:ok, selection} = ModelResolver.resolve("openai:not-a-codex-name", opts)
    record = selection |> ModelSelection.encode() |> JSON.encode!() |> JSON.decode!()

    assert {:ok, restored} = ModelResolver.restore(record, opts)
    assert restored.policy.limits.context == nil
    assert restored.policy.capabilities.tools == false
    assert restored.request_model == selection.request_model
    assert ModelSelection.id(restored) == ModelSelection.id(selection)
  end

  test "picker candidates remain unverified and match opaque favorite ids" do
    base_opts =
      Snapshot.new(%{"openai" => :env}, nil, "http://localhost")
      |> resolver_opts()
      |> Keyword.put(:models, [@catalog_model])

    assert [initial] = ModelResolver.candidates(base_opts)
    favorite_id = ModelSelection.id(initial.selection)

    assert [candidate] =
             ModelResolver.candidates(Keyword.put(base_opts, :favorites, [favorite_id]))

    assert candidate.selection.evidence.status == :unverified
    assert candidate.favorite
    assert ModelSelection.id(candidate.selection) == favorite_id
  end

  test "rejects a catalog route explicitly unavailable for text execution" do
    model = %{
      @catalog_model
      | execution: %{text: %{supported: false, wire_protocol: "openai_responses"}}
    }

    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil, "http://localhost"))

    assert {:error, {:route_unavailable, _}} =
             ModelResolver.resolve("openai:not-a-codex-name", Keyword.put(opts, :models, [model]))
  end

  test "rejects explicit false streaming capability rather than treating it as unknown" do
    model = %{
      @catalog_model
      | capabilities: %{streaming: %{text: false}, tools: %{enabled: false}}
    }

    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil, "http://localhost"))

    assert {:error, {:incompatible_selection, _}} =
             ModelResolver.resolve("openai:not-a-codex-name", Keyword.put(opts, :models, [model]))
  end

  test "rejects credential-bearing base URLs without disclosing their values" do
    for endpoint <- [
          "https://user:synthetic-secret@api.example/v1",
          "https://api.example/v1?key=synthetic-secret",
          "https://api.example/v1#synthetic-secret"
        ] do
      config = %Config{api_base_url: endpoint}
      opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil, "http://localhost"), config)

      assert {:error, {:route_unavailable, message}} =
               ModelResolver.resolve("openai:not-a-codex-name", opts)

      refute message =~ "synthetic-secret"
    end
  end

  test "extracts supported reasoning values from catalog effort metadata" do
    model = %{
      @catalog_model
      | extra: %{
          "reasoning_options" => [
            %{"type" => "effort", "values" => ["none", "low", "high", "xhigh"]}
          ]
        }
    }

    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil, "http://localhost"))

    assert {:ok, selection} =
             ModelResolver.resolve(
               %{"model" => "openai:not-a-codex-name", "reasoning_effort" => "xhigh"},
               Keyword.put(opts, :models, [model])
             )

    assert selection.policy.reasoning.options == ["default", "none", "low", "high", "xhigh"]
    assert selection.policy.reasoning.effort == "xhigh"
  end

  defp resolver_opts(snapshot, config \\ %Config{max_tokens: 4_096}) do
    [
      backend_spec: Native.spec(),
      credential_snapshot: snapshot,
      config: config,
      models: [@catalog_model],
      providers: [@provider]
    ]
  end
end
