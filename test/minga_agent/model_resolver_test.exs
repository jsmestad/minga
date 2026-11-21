defmodule MingaAgent.ModelResolverTest do
  use ExUnit.Case, async: true

  alias MingaAgent.CodexModels
  alias MingaAgent.Config
  alias MingaAgent.Credentials
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.OAuth
  alias MingaAgent.ProviderPacks.Native
  alias MingaAgent.Test.ModelSelectionFixture

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

  test "a fresh unconfigured profile skips catalog acquisition, including favorites" do
    opts = [
      credential_snapshot: Snapshot.new(%{}, nil),
      backend_spec: Native.spec(),
      models: :catalog_must_not_be_enumerated,
      favorites: ["openai:not-a-codex-name"]
    ]

    assert ModelResolver.candidates(opts) == []
  end

  test "an unsupported credential does not enable catalog discovery" do
    opts = [
      credential_snapshot: Snapshot.new(%{"unsupported" => :env}, nil),
      backend_spec: Native.spec(),
      models: :catalog_must_not_be_enumerated
    ]

    assert ModelResolver.candidates(opts) == []
  end

  test "an explicitly configured Apple route persists its exact local identity without probing" do
    opts = resolver_opts(Snapshot.new(%{}, nil))

    opts =
      Keyword.put(opts, :apple_availability_fn, fn -> flunk("unexpected readiness probe") end)

    assert {:ok, selection} = ModelResolver.resolve("apple:system", opts)
    assert selection.route.display_name == "Apple Intelligence (On Device)"
    assert selection.route.origin == {:local, "apple", "system"}
    assert %LLMDB.Model{provider: :apple, id: "system", base_url: nil} = selection.request_model
    assert selection.credential == :none
    assert selection.policy.limits.context == nil
    assert selection.policy.limits.request_output == 512
    assert selection.policy.capabilities.tools == true
    assert selection.policy.capabilities.images == false
    assert {:ok, []} = Credentials.request_options(selection.credential, [])

    assert {:ok, %{material: [], identity: %{kind: :none}}} =
             Credentials.bind_request(selection.credential, nil, [])

    encoded = selection |> ModelSelection.encode() |> JSON.encode!() |> JSON.decode!()
    assert encoded["credential"] == %{"kind" => "none"}
    assert encoded["route"]["execution"]["transport"] == "in_process"
    assert encoded["route"]["execution"]["base_url"] == nil
    assert encoded["route"]["execution"]["path"] == nil

    assert {:ok, ^selection} = ModelResolver.restore(encoded, opts)
    assert {:ok, ^selection} = ModelResolver.resolve(ModelSelection.id(selection), opts)
    assert {:error, :no_available_model} = ModelResolver.resolve(nil, opts)

    assert {:error, :invalid_route} =
             encoded
             |> put_in(["route", "execution", "base_url"], "https://proxy.example/v1")
             |> ModelSelection.decode()

    assert {:error, :invalid_credential} =
             encoded
             |> Map.put("credential", %{
               "kind" => "api_key",
               "provider" => "apple",
               "source" => "env"
             })
             |> ModelSelection.decode()

    hosted = ModelSelectionFixture.selection() |> ModelSelection.encode()

    assert {:error, :invalid_credential} =
             hosted |> Map.put("credential", encoded["credential"]) |> ModelSelection.decode()
  end

  test "Apple discovery needs readiness and activation checks again without falling back" do
    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil))
    opts = Keyword.put(opts, :apple_discovery, {:ok, 4_096})

    assert [apple, hosted] = ModelResolver.candidates(opts)
    assert apple.selection.route.request_provider == :apple
    assert apple.selection.policy.limits.context == 4_096
    assert hosted.selection.route.request_provider == :openai

    opts =
      Keyword.merge(opts,
        apple_availability_fn: fn -> {:error, :disabled} end,
        apple_discovery: {:error, :disabled},
        require_apple_ready: true
      )

    assert [^hosted] = ModelResolver.candidates(opts)

    assert {:error, {:selection_correction_required, message}} =
             ModelResolver.resolve(apple.selection, opts)

    assert message =~ "Enable it in System Settings"
    assert {:error, {:route_unavailable, ^message}} = ModelResolver.resolve("apple:system", opts)
    assert {:error, {:route_unavailable, _message}} = ModelResolver.resolve("apple:other", opts)
  end

  test "keeps catalog routes unverified without exact model evidence" do
    assert {:ok, selection} =
             ModelResolver.resolve(
               %{"model" => "openai:not-a-codex-name", "reasoning_effort" => "high"},
               resolver_opts(Snapshot.new(%{"openai" => :env}, nil))
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
    assert selection.policy.capabilities.tool_result_images == false
    assert selection.evidence.status == :unverified
  end

  test "catalog OpenAI Responses enables tool-result images only with image input" do
    model = put_in(@catalog_model, [:modalities, "input"], ["text", "image"])
    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil))

    assert {:ok, selection} =
             ModelResolver.resolve(
               "openai:not-a-codex-name",
               Keyword.put(opts, :models, [model])
             )

    assert selection.policy.capabilities.images == true
    assert selection.policy.capabilities.tool_result_images == true
    assert ModelSelection.image_tool_result_delivery(selection) == :supported

    legacy =
      selection
      |> ModelSelection.encode()
      |> Map.put("version", 2)
      |> update_in(["policy", "capabilities"], &Map.delete(&1, "tool_result_images"))

    assert {:ok, restored} = ModelResolver.restore(legacy, Keyword.put(opts, :models, [model]))
    assert ModelSelection.image_tool_result_delivery(restored) == :supported

    oauth = OAuth.new("account-image", "/tmp/minga-image-oauth.json")
    codex_snapshot = Snapshot.new(%{"openai" => :env}, oauth)

    codex_opts =
      codex_snapshot
      |> resolver_opts()
      |> Keyword.put(:models, [model])
      |> Keyword.put(:candidate_resolution, true)

    assert {:ok, codex} =
             ModelResolver.resolve("openai_codex:not-a-codex-name", codex_opts)

    assert codex.route.execution.wire_protocol == "openai_codex_responses"
    assert ModelSelection.image_tool_result_delivery(codex) == :supported
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
      Snapshot.new(%{"openai" => :env}, nil)
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
      Snapshot.new(%{"openai" => :env}, nil)
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

  test "keeps API-key and OAuth profiles as distinct exact routes" do
    snapshot =
      Snapshot.new(
        %{"openai" => :env},
        OAuth.new("account-123", "/tmp/minga-resolver-oauth.json")
      )

    opts = resolver_opts(snapshot)
    candidates = ModelResolver.candidates(opts)

    assert [_, _] = candidates

    assert api_key =
             Enum.find(candidates, &(&1.selection.route.request_provider == :openai))

    assert oauth =
             Enum.find(candidates, &(&1.selection.route.request_provider == :openai_codex))

    assert ModelSelection.credential_id(api_key.selection.credential) == "openai:env"
    assert api_key.selection.route.execution.wire_protocol == "openai_responses"

    assert ModelSelection.credential_id(oauth.selection.credential) ==
             "openai-codex:account-123"

    assert oauth.selection.route.execution.wire_protocol == "openai_codex_responses"
    assert oauth.selection.route.execution.base_url == "https://chatgpt.com/backend-api"
    api_key_id = ModelSelection.id(api_key.selection)
    refute api_key_id == ModelSelection.id(oauth.selection)

    assert {:ok, selection} = ModelResolver.resolve(api_key_id, opts)
    assert selection == api_key.selection

    oauth_only =
      Keyword.put(opts, :credential_snapshot, Snapshot.new(%{}, oauth.selection.credential))

    assert [^oauth] = ModelResolver.candidates(oauth_only)

    assert {:error, {:selection_correction_required, message}} =
             ModelResolver.resolve(api_key_id, oauth_only)

    assert message =~ "The exact saved route is no longer available"
  end

  test "account discovery exposes only listed wire IDs without hiding API-key routes" do
    credential = OAuth.new("account-a", "/tmp/model-discovery-a.json")
    snapshot = Snapshot.new(%{"openai" => :env}, credential)

    daybreak = %{
      @catalog_model
      | id: "gpt-daybreak-blue-latest",
        provider_model_id: "gpt-daybreak-blue-latest"
    }

    assert {:ok, inventory} =
             CodexModels.from_response(credential, %{
               "models" => [
                 %{"slug" => "not-a-codex-name", "visibility" => "list"},
                 %{"slug" => "gpt-daybreak-blue-latest", "visibility" => "hide"}
               ]
             })

    opts = Keyword.merge(resolver_opts(snapshot), models: [@catalog_model, daybreak])

    route_keys = fn evidence ->
      opts
      |> Keyword.put(:codex_models, evidence)
      |> ModelResolver.candidates()
      |> MapSet.new(&{&1.selection.route.request_provider, &1.selection.route.model_id})
    end

    api_key_routes = [
      {:openai, "not-a-codex-name"},
      {:openai, "gpt-daybreak-blue-latest"}
    ]

    assert route_keys.({:ok, inventory}) ==
             MapSet.new([{:openai_codex, "not-a-codex-name"} | api_key_routes])

    assert route_keys.({:error, {:http_status, 401}}) == MapSet.new(api_key_routes)

    other_credential = OAuth.new("account-b", "/tmp/model-discovery-a.json")
    other_opts = Keyword.put(opts, :credential_snapshot, Snapshot.new(%{}, other_credential))

    assert ModelResolver.candidates(Keyword.put(other_opts, :codex_models, {:ok, inventory})) ==
             []
  end

  test "restore rejects imported catalog execution and credential-owner substitution" do
    opts =
      resolver_opts(Snapshot.new(%{"openai" => :env, "anthropic" => :env}, nil))

    {:ok, selection} = ModelResolver.resolve("openai:not-a-codex-name", opts)
    encoded = ModelSelection.encode(selection)

    changes = [
      {["route", "execution", "base_url"], "https://attacker.example/v1"},
      {["route", "execution", "path"], "/collect"},
      {["route", "execution", "provider_model_id"], "different-model"},
      {["credential", "provider"], "anthropic"}
    ]

    for {path, replacement} <- changes do
      assert {:error, {:selection_correction_required, _message}} =
               encoded |> put_in(path, replacement) |> ModelResolver.restore(opts)
    end

    unavailable = Keyword.merge(opts, credential_snapshot: Snapshot.new(%{}, nil), models: [])
    wrong_backend = Map.put(encoded, "backend_id", "different-backend")

    assert {:error, {:selection_correction_required, message}} =
             ModelResolver.restore(wrong_backend, unavailable)

    assert message =~ "The saved model selection belongs to a different backend"
  end

  test "display-name changes preserve the executable selection identity" do
    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil))
    {:ok, original} = ModelResolver.resolve("openai:not-a-codex-name", opts)
    updated = Keyword.put(opts, :models, [%{@catalog_model | name: "Renamed Catalog Label"}])
    {:ok, renamed} = ModelResolver.resolve("openai:not-a-codex-name", updated)
    assert ModelSelection.id(original) == ModelSelection.id(renamed)
    assert {:ok, restored} = ModelResolver.restore(original, updated)
    assert restored.route.execution == original.route.execution
  end

  test "OAuth persistence binds a source without serializing its filesystem path" do
    path = "/tmp/private-source-a/oauth.json"
    snapshot = Snapshot.new(%{}, OAuth.new("same-account", path))
    [candidate] = ModelResolver.candidates(resolver_opts(snapshot))
    encoded = ModelSelection.encode(candidate.selection)
    refute JSON.encode!(encoded) =~ path
    assert encoded["credential"]["source_id"] == OAuth.new("same-account", path).source_id

    changed =
      Snapshot.new(
        %{},
        OAuth.new("same-account", "/tmp/private-source-b/oauth.json")
      )

    assert {:error, {:selection_correction_required, _message}} =
             ModelResolver.restore(encoded, resolver_opts(changed))
  end

  test "restoration refuses to switch to another credential source" do
    {:ok, selection} =
      ModelResolver.resolve(
        "openai:not-a-codex-name",
        resolver_opts(Snapshot.new(%{"openai" => :env}, nil))
      )

    assert {:error, {:selection_correction_required, message}} =
             ModelResolver.restore(
               selection,
               resolver_opts(Snapshot.new(%{"openai" => :file}, nil))
             )

    assert message =~ "openai:env"
    refute message =~ "API key"
  end

  test "exact image tool-result decisions compose model input and route transport gates" do
    supported = %{tools: true, images: true, tool_result_images: true, streaming: true}
    no_transport = %{supported | tool_result_images: false}
    no_input = %{supported | images: false}

    selections = [
      ModelSelectionFixture.selection(request_provider: :anthropic, capabilities: supported),
      ModelSelectionFixture.selection(
        request_provider: :openai,
        family: "openai_responses_compatible",
        wire_protocol: "openai_responses",
        path: "/responses",
        capabilities: supported
      ),
      ModelSelectionFixture.selection(request_provider: :openai_codex, capabilities: supported),
      ModelSelectionFixture.selection(request_provider: :google, capabilities: supported)
    ]

    assert Enum.all?(selections, &(ModelSelection.image_tool_result_delivery(&1) == :supported))

    assert ModelSelection.image_tool_result_delivery(
             ModelSelectionFixture.selection(capabilities: no_transport)
           ) == {:unsupported, :tool_result_transport}

    assert ModelSelection.image_tool_result_delivery(
             ModelSelectionFixture.selection(capabilities: no_input)
           ) == {:unsupported, :model_image_input}
  end

  test "legacy favorites migrate unique routes but never guess between API-key and OAuth profiles" do
    unique_snapshot = Snapshot.new(%{"openai" => :env}, nil)

    unique_candidates =
      ModelResolver.candidates(
        Keyword.put(resolver_opts(unique_snapshot), :favorites, ["openai:not-a-codex-name"])
      )

    assert [
             %MingaAgent.ModelCandidate{
               selection: %{
                 credential: %MingaAgent.ModelSelection.Credential.ApiKey{
                   provider: "openai",
                   source: :env
                 }
               }
             }
           ] =
             Enum.filter(unique_candidates, & &1.favorite)

    snapshot =
      Snapshot.new(
        %{"openai" => :env},
        OAuth.new("favorite-account", "/tmp/favorite-oauth.json")
      )

    candidates =
      ModelResolver.candidates(
        Keyword.put(resolver_opts(snapshot), :favorites, ["openai:not-a-codex-name"])
      )

    assert [] = Enum.filter(candidates, & &1.favorite)

    assert Enum.any?(candidates, fn candidate ->
             match?(%OAuth{}, candidate.selection.credential) and not candidate.favorite
           end)
  end

  test "catalog capabilities produce an executable selection and survive restore" do
    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil))

    assert {:ok, selection} = ModelResolver.resolve("openai:not-a-codex-name", opts)

    assert ModelSelection.tools?(selection)
    refute ModelSelection.images?(selection)

    assert {:ok, restored} =
             selection |> ModelSelection.encode() |> ModelResolver.restore(opts)

    assert ModelSelection.id(restored) == ModelSelection.id(selection)
    assert ModelSelection.tools?(restored)
    refute ModelSelection.images?(restored)
  end

  test "serialized identity is versioned and contains no credential value" do
    {:ok, selection} =
      ModelResolver.resolve(
        "openai:not-a-codex-name",
        resolver_opts(Snapshot.new(%{"openai" => :env}, nil))
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

  test "JSON restoration preserves unknown limits and streaming alongside explicitly unsupported tools" do
    model = %{
      @catalog_model
      | limits: %{context: nil, input: nil, output: nil},
        capabilities: %{tools: %{enabled: false}}
    }

    opts =
      Snapshot.new(%{"openai" => :env}, nil)
      |> resolver_opts()
      |> Keyword.put(:models, [model])

    {:ok, selection} = ModelResolver.resolve("openai:not-a-codex-name", opts)
    record = selection |> ModelSelection.encode() |> JSON.encode!() |> JSON.decode!()

    assert {:ok, restored} = ModelResolver.restore(record, opts)
    assert restored.policy.limits.context == nil
    assert restored.policy.capabilities.tools == false
    assert restored.policy.capabilities.streaming == :unknown
    assert restored.request_model == selection.request_model
    assert ModelSelection.id(restored) == ModelSelection.id(selection)
  end

  test "picker candidates remain unverified and match opaque favorite ids" do
    base_opts =
      Snapshot.new(%{"openai" => :env}, nil)
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

    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil))

    assert {:error, {:route_unavailable, _}} =
             ModelResolver.resolve("openai:not-a-codex-name", Keyword.put(opts, :models, [model]))
  end

  test "rejects explicit false streaming in fresh and restored hosted selections" do
    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil))
    intent = "openai:not-a-codex-name"
    model = put_in(@catalog_model, [:capabilities, "streaming", "text"], false)
    no_streaming = Keyword.put(opts, :models, [model])

    assert {:error, {:incompatible_selection, message}} =
             ModelResolver.resolve(intent, no_streaming)

    assert message =~ "Exact Catalog Model does not support streaming text responses"

    assert {:ok, selection} = ModelResolver.resolve(intent, opts)

    encoded =
      selection
      |> ModelSelection.encode()
      |> put_in(["route", "metadata", "capabilities", "streaming", "text"], false)
      |> put_in(["policy", "capabilities", "streaming"], false)

    assert {:error, {:selection_correction_required, ^message}} =
             ModelResolver.restore(encoded, no_streaming)
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

    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil))

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
