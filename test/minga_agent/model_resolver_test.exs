defmodule MingaAgent.ModelResolverTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config
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
      credential_snapshot: Snapshot.new(%{}, nil, "http://localhost"),
      backend_spec: Native.spec(),
      models: :catalog_must_not_be_enumerated,
      favorites: ["openai:not-a-codex-name"]
    ]

    assert ModelResolver.candidates(opts) == []
  end

  test "an unsupported credential does not enable catalog discovery" do
    opts = [
      credential_snapshot: Snapshot.new(%{"unsupported" => :env}, nil, "http://localhost"),
      backend_spec: Native.spec(),
      models: :catalog_must_not_be_enumerated
    ]

    assert ModelResolver.candidates(opts) == []
  end

  test "explicit local routes remain selectable without implicit Ollama discovery" do
    local_model = %{
      @catalog_model
      | id: "local-model",
        provider: :ollama,
        provider_model_id: "local-model",
        execution: %{
          text: %{
            supported: true,
            family: "openai_chat_compatible",
            wire_protocol: "openai_chat",
            transport: "http",
            provider_model_id: "local-model",
            base_url: "http://localhost:11434",
            path: "/chat/completions"
          }
        },
        extra: %{}
    }

    opts = [
      credential_snapshot: Snapshot.new(%{}, nil, "http://localhost:11434"),
      backend_spec: Native.spec(),
      models: [local_model],
      providers: [%{id: :ollama, runtime: %{"base_url" => "http://localhost:11434"}}]
    ]

    assert ModelResolver.candidates(opts) == []

    [candidate] =
      ModelResolver.candidates(Keyword.put(opts, :config, %Config{model: "ollama:local-model"}))

    assert candidate.selection.route.request_provider == :ollama
    id = ModelSelection.id(candidate.selection)
    assert {:ok, selection} = ModelResolver.resolve(id, opts)
    assert ModelSelection.id(selection) == id

    [current] = ModelResolver.candidates(Keyword.put(opts, :current, selection))
    assert current.selection == selection
  end

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
    assert selection.policy.capabilities.tool_result_images == false
    assert selection.evidence.status == :unverified
  end

  test "catalog OpenAI Responses enables tool-result images only with image input" do
    model = put_in(@catalog_model, [:modalities, "input"], ["text", "image"])
    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil, "http://localhost"))

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
    codex_snapshot = Snapshot.new(%{"openai" => :env}, oauth, "http://localhost")

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

  test "keeps API-key and OAuth profiles as distinct exact routes" do
    snapshot =
      Snapshot.new(
        %{"openai" => :env},
        OAuth.new("account-123", "/tmp/minga-resolver-oauth.json"),
        "http://localhost"
      )

    candidates =
      snapshot
      |> resolver_opts()
      |> ModelResolver.candidates()

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
    refute ModelSelection.id(api_key.selection) == ModelSelection.id(oauth.selection)
  end

  test "restore rejects imported catalog execution and credential-owner substitution" do
    opts =
      resolver_opts(
        Snapshot.new(%{"openai" => :env, "anthropic" => :env}, nil, "http://localhost")
      )

    {:ok, selection} = ModelResolver.resolve("openai:not-a-codex-name", opts)
    encoded = ModelSelection.encode(selection)

    changes = [
      {["route", "execution", "base_url"], "https://attacker.example/v1"},
      {["route", "execution", "path"], "/collect"},
      {["route", "execution", "provider_model_id"], "different-model"},
      {["credential", "provider"], "anthropic"},
      {["backend_id"], "different-backend"}
    ]

    for {path, replacement} <- changes do
      assert {:error, {:selection_correction_required, _message}} =
               encoded |> put_in(path, replacement) |> ModelResolver.restore(opts)
    end
  end

  test "display-name changes preserve the executable selection identity" do
    opts = resolver_opts(Snapshot.new(%{"openai" => :env}, nil, "http://localhost"))
    {:ok, original} = ModelResolver.resolve("openai:not-a-codex-name", opts)
    updated = Keyword.put(opts, :models, [%{@catalog_model | name: "Renamed Catalog Label"}])
    {:ok, renamed} = ModelResolver.resolve("openai:not-a-codex-name", updated)
    assert ModelSelection.id(original) == ModelSelection.id(renamed)
    assert {:ok, restored} = ModelResolver.restore(original, updated)
    assert restored.route.execution == original.route.execution
  end

  test "OAuth persistence binds a source without serializing its filesystem path" do
    path = "/tmp/private-source-a/oauth.json"
    snapshot = Snapshot.new(%{}, OAuth.new("same-account", path), "http://localhost")
    [candidate] = ModelResolver.candidates(resolver_opts(snapshot))
    encoded = ModelSelection.encode(candidate.selection)
    refute JSON.encode!(encoded) =~ path
    assert encoded["credential"]["source_id"] == OAuth.new("same-account", path).source_id

    changed =
      Snapshot.new(
        %{},
        OAuth.new("same-account", "/tmp/private-source-b/oauth.json"),
        "http://localhost"
      )

    assert {:error, {:selection_correction_required, _message}} =
             ModelResolver.restore(encoded, resolver_opts(changed))
  end

  test "explicit configured model ownership overrides a same-id catalog model" do
    config = %Config{
      api_endpoints: %{
        "openai" => %{
          "url" => "http://127.0.0.1:9000/v1",
          "protocol" => "openai_chat",
          "auth_mode" => "none",
          "models" => %{
            "not-a-codex-name" => %{
              "provider_model_id" => "gateway-wire-alias",
              "capabilities" => %{"tools" => false, "streaming" => true},
              "limits" => %{"output" => 100}
            }
          }
        }
      }
    }

    opts = resolver_opts(Snapshot.new(%{}, nil, "http://localhost"), config)
    assert {:ok, selection} = ModelResolver.resolve("openai:not-a-codex-name", opts)
    assert selection.route.execution.provider_model_id == "gateway-wire-alias"
    assert selection.request_model.id == "gateway-wire-alias"
    assert selection.policy.capabilities.tools == false
    assert selection.policy.limits.output == 100
    assert {:ok, _restored} = ModelResolver.restore(selection, opts)

    [candidate] =
      ModelResolver.candidates(Keyword.put(opts, :models, :catalog_must_not_be_loaded))

    assert candidate.selection.route.execution.provider_model_id == "gateway-wire-alias"
  end

  test "restore rejects changed custom capability and wire-model declarations" do
    config = MingaAgent.Test.ModelSelectionFixture.config()
    opts = resolver_opts(Snapshot.new(%{}, nil, "http://localhost"), config)
    {:ok, selection} = ModelResolver.resolve("test:test-model", opts)

    for {path, replacement} <- [
          {[:api_endpoints, "test", "models", "test-model", "capabilities", "tools"], false},
          {[:api_endpoints, "test", "models", "test-model", "provider_model_id"],
           "changed-wire-id"}
        ] do
      changed = put_in(config, [Access.key(:api_endpoints) | tl(path)], replacement)

      assert {:error, {:selection_correction_required, _message}} =
               ModelResolver.restore(selection, Keyword.put(opts, :config, changed))
    end
  end

  test "custom Anthropic and Google routes reject anonymous authentication before activation" do
    for protocol <- ["anthropic_messages", "google_generate_content"] do
      config = %Config{
        api_endpoints: %{
          "private" => %{
            "url" => "http://127.0.0.1:9000",
            "protocol" => protocol,
            "auth_mode" => "none",
            "models" => %{"alias" => %{"provider_model_id" => "wire-model"}}
          }
        }
      }

      opts = resolver_opts(Snapshot.new(%{}, nil, "http://localhost"), config)

      assert {:error, {:route_unavailable, _message}} =
               ModelResolver.resolve("private:alias", opts)
    end
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
    assert selection.policy.capabilities.tool_result_images == :unknown
    assert selection.policy.capabilities.streaming == :unknown
    assert selection.evidence.status == :unverified

    legacy =
      selection
      |> ModelSelection.encode()
      |> Map.put("version", 2)
      |> update_in(["policy", "capabilities"], &Map.delete(&1, "tool_result_images"))

    assert {:ok, legacy_stored} = ModelSelection.decode(legacy)
    assert legacy_stored.policy.capabilities.tool_result_images == :unknown

    assert {:ok, legacy_restored} =
             ModelResolver.restore(
               legacy,
               resolver_opts(Snapshot.new(%{}, nil, "http://localhost"), config)
             )

    assert ModelSelection.image_tool_result_delivery(legacy_restored) ==
             {:unsupported, :model_image_input}
  end

  @tag :tmp_dir
  test "a non-vendor custom endpoint uses its exact file credential and survives restore", %{
    tmp_dir: dir
  } do
    secret = "private-endpoint-file-key"
    credential_opts = [config_dir: dir, oauth_identity_probe: fn -> nil end]
    assert :ok = MingaAgent.Credentials.store("private", secret, credential_opts)
    snapshot = MingaAgent.Credentials.snapshot(credential_opts)

    config = %Config{
      api_endpoints: %{
        "private" => %{
          "url" => "https://private.example/v1",
          "protocol" => "openai_chat",
          "auth_mode" => "api_key",
          "models" => %{
            "exact-custom" => %{
              "capabilities" => %{"tools" => true, "images" => false, "streaming" => true},
              "limits" => %{"context" => 32_000, "output" => 2_000}
            }
          }
        }
      }
    }

    opts = resolver_opts(snapshot, config)
    assert {:ok, selection} = ModelResolver.resolve("private:exact-custom", opts)

    assert selection.credential ==
             MingaAgent.ModelSelection.Credential.ApiKey.new("private", :file)

    assert selection.route.execution.base_url == "https://private.example/v1"
    assert selection.route.execution.provider_model_id == "exact-custom"

    assert {:ok, request_opts} =
             MingaAgent.Credentials.request_options(selection.credential, credential_opts)

    assert request_opts[:api_key] == secret
    encoded = ModelSelection.encode(selection)
    refute JSON.encode!(encoded) =~ secret
    assert {:ok, restored} = ModelResolver.restore(encoded, opts)
    assert ModelSelection.id(restored) == ModelSelection.id(selection)
    File.write!(Path.join([dir, "minga", "credentials.json"]), "{}")

    assert {:error, {:credential_unavailable, "private:file"}} =
             MingaAgent.Credentials.request_options(restored.credential, credential_opts)
  end

  test "custom image input does not authorize tool-result transport without an explicit declaration" do
    base_model = %{
      "name" => "Exact Custom",
      "capabilities" => %{"tools" => true, "images" => true, "streaming" => true}
    }

    endpoint = %{
      "url" => "http://127.0.0.1:9000/v1",
      "protocol" => "openai_chat",
      "auth_mode" => "none",
      "models" => %{"exact" => base_model}
    }

    opts =
      resolver_opts(
        Snapshot.new(%{}, nil, "http://localhost"),
        %Config{api_endpoints: %{"custom" => endpoint}}
      )

    assert {:ok, ordinary} = ModelResolver.resolve("custom:exact", opts)

    assert ModelSelection.image_tool_result_delivery(ordinary) ==
             {:unsupported, :tool_result_transport}

    explicit_endpoint =
      put_in(
        endpoint,
        ["models", "exact", "capabilities", "tool_result_images"],
        true
      )

    explicit_opts =
      resolver_opts(
        Snapshot.new(%{}, nil, "http://localhost"),
        %Config{api_endpoints: %{"custom" => explicit_endpoint}}
      )

    assert {:ok, explicit} = ModelResolver.resolve("custom:exact", explicit_opts)
    assert ModelSelection.image_tool_result_delivery(explicit) == :supported
    assert ModelSelection.encode(explicit)["policy"]["capabilities"]["tool_result_images"] == true
    assert {:ok, restored} = ModelResolver.restore(ModelSelection.encode(explicit), explicit_opts)
    assert ModelSelection.image_tool_result_delivery(restored) == :supported
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
    unique_snapshot = Snapshot.new(%{"openai" => :env}, nil, "http://localhost")

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
        OAuth.new("favorite-account", "/tmp/favorite-oauth.json"),
        "http://localhost"
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

  test "custom boolean capabilities produce an executable selection and survive restore" do
    config = MingaAgent.Test.ModelSelectionFixture.config()
    opts = resolver_opts(Snapshot.new(%{}, nil, "http://localhost"), config)

    assert {:ok, selection} =
             ModelResolver.resolve(MingaAgent.Test.ModelSelectionFixture.model_intent(), opts)

    assert ModelSelection.tools?(selection)
    assert ModelSelection.images?(selection)

    assert {:ok, restored} =
             selection |> ModelSelection.encode() |> ModelResolver.restore(opts)

    assert ModelSelection.id(restored) == ModelSelection.id(selection)
    assert ModelSelection.tools?(restored)
    assert ModelSelection.images?(restored)
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
