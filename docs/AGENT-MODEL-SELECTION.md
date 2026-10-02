# Agent model selection

Minga resolves every agent model choice to one exact hosted route before it becomes active. The route records the backend, catalog model identity, request provider, wire protocol, provider endpoint, provider-facing model ID, credential profile, reasoning controls, limits, and capabilities. Prompt transport consumes that resolved route directly.

Minga supports these named hosted providers:

| Request provider | Credential identity |
|---|---|
| Anthropic | API key from the environment or credential file |
| OpenAI | API key from the environment or credential file |
| OpenAI Codex | Exact OAuth account and source file |
| Google | API key from the environment or credential file |
| OpenRouter | API key from the environment or credential file |
| Groq | API key from the environment or credential file |
| Mistral | API key from the environment or credential file |
| DeepSeek | API key from the environment or credential file |

Local inference servers, anonymous routes, custom endpoints, and provider endpoint overrides are not supported.

## Configure a model

Set a hosted provider and catalog model:

```elixir
set :agent_model, "anthropic:claude-sonnet-4-20250514"
```

Configure the matching credential with `/auth`, `/login` for OpenAI Codex, or the provider environment variable. Open `/model` to list the routes available for the credentials configured on the current machine.

The picker and slash completion show:

- model provider and wire protocol;
- hosted endpoint and canonical protocol path;
- secret-free credential profile;
- reasoning controls and context limit;
- tool, image, and streaming capability evidence; and
- favorite and current status.

A choice becomes active only after the current session validates the exact catalog route and credential. An unsupported provider, missing catalog model, unavailable credential, or incompatible capability returns an error and leaves the previous route active. Minga does not fall back to another model, provider, credential source, or endpoint.

## Saved selections

Credential values are never stored in the selection. API-key selections store only the provider and source (`env` or `file`). OpenAI Codex selections store the OAuth account identity and a hash of the source identity; the OAuth filesystem path remains request-local.

Saved sessions persist the complete secret-free route snapshot. Restore validates the recorded backend, catalog route, credential owner and source, execution contract, and capabilities against the current hosted catalog. Changed catalog data or a revoked credential requires a new selection through `/model`.

Favorites should use the opaque ID shown by completion or the picker. These IDs hash the executable route identity. Do not derive them from display labels.

## Capability policy

Catalog capability values are evidence, not guesses. `unknown` is displayed explicitly and treated conservatively:

- Native turns are rejected before transport when tools are configured but tool support is not explicitly `true`.
- Image attachments and history are rejected before transport unless image support is explicitly `true`.
- `/thinking` changes are rejected unless the exact route advertises the requested reasoning control.
- Rejection preserves the previous active selection and includes a corrective message.

Retained image tool results need both `images: true` and `tool_result_images: true` on the exact route. Ordinary image input support alone does not prove that the protocol accepts an image inside a tool result. Minga derives the transport gate for catalog Anthropic Messages and OpenAI Responses or Codex routes. OpenAI Chat remains conservative. Google transport support also requires explicit evidence.

Unsupported image tool results are recoverable, model-visible tool errors, not empty successful reads. They do not disable ordinary user image attachments when those attachments are supported. See [Session Recovery](SESSION-RECOVERY.md#retained-tool-output) for retained bytes.

Selection codec version 3 adds the transport capability and reads version 2 conservatively. Stable route identities keep the `ms2_` identity schema; adding a delivery capability does not rename the route.

Catalog presence and an installed adapter do not prove that every model has passed a maintained vendor integration test.
