# Agent model selection

Minga resolves every agent model choice to one exact, immutable route before it becomes active. The route records the backend, catalog or custom model identity, ReqLLM request provider, wire protocol, base URL, path, provider-facing model ID, credential profile, reasoning controls, limits, capabilities, and provenance. Prompt transport consumes that resolved route directly; it does not infer a provider from a model-name substring.

Credential values are never stored in the selection. The saved identity is only the provider and source (`env` or `file`), an exact OAuth account and hashed source identity, or an explicit anonymous route. OAuth filesystem paths remain request-local and are not exported or persisted.

## Choosing a route

Open the model picker with `/model`, or enter `/model <id>` when you already have an exact picker ID. Display names are not identities: two routes can show the same model name while using different protocols, endpoints, or credentials.

The picker and slash completion show:

- model provider and wire protocol;
- complete endpoint and canonical protocol path;
- secret-free credential profile;
- catalog or custom provenance and verification status;
- reasoning controls and context limit;
- tool, image, and streaming capability evidence; and
- favorite/current status.

A choice is activated only after the current agent session validates it. Rejection leaves the previous route visible and active. Starting `/model` without an active agent session also leaves the previous display unchanged, because no session is available to validate the route.

Local Ollama choices remain pending while the session probes the exact configured endpoint. The previous route continues serving the conversation during that probe. Only a correlated successful probe may install the candidate, update the panel, and persist it; an unavailable route or provider rejection reports the candidate identity and leaves the previous route unchanged.

## Migrating existing configuration and sessions

The existing string setting remains the configuration boundary:

```elixir
set :agent_model, "anthropic:claude-sonnet-4-20250514"
```

At startup Minga resolves that intent against the pinned catalog, the installed native backend, and the credentials available at that moment. If the intent is ambiguous, unsupported, or unavailable, resolution fails with a corrective message rather than selecting a nearby model or credential.

Legacy `provider:model` favorites migrate to exact route IDs only when that name resolves to one available credential route. If API-key and OAuth routes both match, Minga reports the ambiguity and leaves the favorite unset. Choose the exact route in `/model` and favorite that choice.

Newly saved sessions persist the complete secret-free route snapshot. On restore Minga validates the recorded backend, credential owner and source, and execution and capability declarations against the installed catalog or current custom configuration. Changed declarations require reselection rather than trusting an imported endpoint or silently replacing the route. Revoking or moving the credential also requires a new selection; Minga never falls back from an environment key to a file key, between OAuth accounts or source files, or to another provider.

Restore readiness is derived from the saved selection rather than the session being replaced. A saved local route is probed before the conversation is replaced, and failure preserves the current conversation. A validated remote route starts a detached provider or resets an exhausted provider lifecycle before restore reports success. Session exports likewise identify the session's active exact route by its opaque selection ID, provider-facing model ID, and wire protocol rather than the mutable global model setting.

Older session data that contains only model/provider intent is migrated only when it resolves uniquely. If it cannot be resolved exactly, open `/model` and choose a replacement. Existing imports remain readable, but the next save writes the current snapshot version.

Favorites should use the opaque ID shown by completion or the picker. IDs are stable hashes of route identity; do not derive them from display labels.

## Custom and local endpoints

Custom endpoints must declare the protocol explicitly. Minga derives the request adapter and canonical path from that protocol; a conflicting configured path is rejected. For example, an anonymous OpenAI-compatible local endpoint can be configured as:

```elixir
set :agent_api_endpoints, %{
  "local" => %{
    "url" => "http://127.0.0.1:4000/v1",
    "protocol" => "openai_chat",
    "auth_mode" => "none",
    "models" => %{
      "my-model" => %{
        "name" => "My local model",
        "provider_model_id" => "my-model-on-the-wire",
        "reasoning_options" => ["off"],
        "limits" => %{"context" => 32_768, "output" => 4_096},
        "capabilities" => %{
          "tools" => true,
          "images" => false,
          "streaming" => true
        }
      }
    }
  }
}

set :agent_model, "local:my-model"
```

Supported custom protocol mappings are:

| Protocol | ReqLLM request provider | Canonical path |
|---|---|---|
| `openai_chat` | OpenAI (`ollama` for endpoint ID `ollama`) | `/chat/completions` |
| `openai_responses` | OpenAI | `/responses` |
| `anthropic_messages` | Anthropic | `/v1/messages` |
| `google_generate_content` | Google | `/models/{provider_model_id}:generateContent` |

`auth_mode` is `api_key` by default and can be set to `none`. Anonymous routes send no authorization header. OAuth credentials are bound to the catalog OpenAI Codex endpoint and cannot be redirected to custom endpoints. A custom route is always labeled **unverified custom route**: configuring it proves that the route is intentional, not that the remote service is compatible.

For an API-key custom endpoint, the credential owner is the endpoint ID, not the wire provider. Store a key for an endpoint named `private` with `MingaAgent.Credentials.store("private", System.fetch_env!("PRIVATE_API_KEY"))`. Native resolves that exact file profile and does not borrow an OpenAI key because the endpoint uses OpenAI's protocol.

## Capability policy

Capability values are evidence, not guesses. `unknown` is displayed explicitly and is treated conservatively:

- Native turns are rejected before transport when tools are configured but tool support is not explicitly `true`.
- Image attachments/history are rejected before transport unless image support is explicitly `true`.
- `/thinking` changes are rejected unless that exact route advertises the requested reasoning control.
- Rejection preserves the previous active selection and includes a corrective message.

Use explicit custom endpoint capability declarations when you control and have tested the server.

## Native provider support matrix

“Installed” below means Minga has an exact ReqLLM request-provider mapping. Catalog candidates additionally require a complete text execution contract from the pinned LLMDB snapshot and an exact local credential. It does **not** mean Minga has run a vendor integration test for every catalog model.

| Request provider | Credential identity | Installed mapping | Maintained vendor verification |
|---|---|---:|---:|
| Anthropic | API key (`env` or `file`) | Yes | No |
| OpenAI | API key (`env` or `file`) | Yes | No |
| OpenAI Codex | exact OAuth account/file | Yes | No |
| Google | API key (`env` or `file`) | Yes | No |
| OpenRouter | API key (`env` or `file`) | Yes | No |
| Groq | API key (`env` or `file`) | Yes | No |
| Mistral | API key (`env` or `file`) | Yes | No |
| DeepSeek | API key (`env` or `file`) | Yes | No |
| Ollama | anonymous configured host | Yes | No |
| Explicit custom route | declared `api_key` or `none` | Protocol-dependent | No |

The picker therefore labels catalog and custom entries as unverified unless future maintained evidence says otherwise. Catalog presence and an installed adapter are not runtime compatibility claims.

## Reproducible validation

Run the local API-key integration smoke in the normal development environment:

```sh
MIX_ENV=dev mix run scripts/smoke_native_model_route.exs
```

The command starts a loopback HTTP server, installs a process-local sentinel `OPENAI_API_KEY`, resolves a custom `openai_chat` route with the exact `openai:env` credential identity, and sends one real native provider request through ReqLLM. It verifies the canonical path, provider-facing model ID, exact authorization header, streamed response, and successful provider completion, then restores the previous environment value. It prints only secret-free JSON evidence and makes no vendor-support claim.

Measure cold and warm picker construction in an optimized environment:

```sh
MIX_ENV=prod mix run bench/agent_model_picker.exs
```

The benchmark reports the exact pinned LLMDB catalog size and SHA-256 fingerprint. “Cold” is the first complete picker candidate build in a fresh optimized BEAM. “Warm” is 100 sequential complete builds in the same process after 10 unmeasured warmups (override samples with `MINGA_BENCH_SAMPLES`). Both measurements include the session call, exact route resolution, sorting, and picker formatting; they exclude rendering, network I/O, and credential value reads.
