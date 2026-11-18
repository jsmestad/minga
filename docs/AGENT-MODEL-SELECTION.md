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

For a Codex subscription, `/model` checks the signed-in account's model list. A model in OpenAI's API catalog is not automatically available through Codex OAuth. If the check fails, the picker explains why it omitted Codex models and still shows routes for configured API keys. Reopen `/model` to refresh the account list used by slash completion.

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

Saved sessions persist the complete secret-free route snapshot. Restore validates the recorded backend, catalog route, credential owner and source, execution contract, and capabilities against the current hosted catalog. A valid selection is not permission to replay retained native context with different inputs.

Favorites should use the opaque ID shown by completion or the picker. These IDs hash the executable route identity. Do not derive them from display labels.

## Native replay identity

The `ms2` selection ID still identifies the configured route, not an API-key principal. An API-key source can contain a different key without changing that ID. Credentials therefore resolves the actual authentication material once per dispatch and passes that same material to transport. A private runtime binding detects replacement before later model calls and retries. No key, token, credential hash, or private source path is stored in a prefix.

API-key continuity cannot be established across a runtime restart from the provider and source alone. Its saved opaque binding is not a durable credential proof. OAuth continuity uses the selected account and source identity and still validates the current credential through its owner.

Exact native replay requires a qualified transport contract. Minga qualifies the official `openai_codex_responses` route at `https://chatgpt.com/backend-api/codex/responses` when the provider-facing model ID matches the selected model. This covers the ordinary Responses encoder and the Responses Lite encoder used by models such as GPT-5.6 Luna. Other supported routes adapt completed history for each request instead of requiring native replay qualification. New reasoning and tool exchanges remain exact throughout the active request.

An older record can contain complete, unchanged inputs that were previously classified as unknown. Minga can requalify that record only when the selection, authentication, instructions, schemas, and selected skills match exactly and transport qualification is the sole difference. It preserves the recorded epochs and messages; it does not reconstruct missing evidence or rewrite the record as if it had always been qualified.

Use `/model` or the model picker to change models between turns without starting another conversation. Minga preserves visible history, text, supported attachments, and completed tool calls and results. It removes provider-specific reasoning signatures, opaque replay blocks, and continuation IDs from the active model history, then saves that history and the new selection together. Saved branch snapshots remain unchanged; boundaries on the active branch now refer to the converted history.

To reopen a branch captured under a different model, first select that model, then switch branches. A mismatched branch switch leaves the active conversation unchanged and names the required route.

Model changes are rejected while a request or unsettled tool group is active. A provider-owned file without portable bytes cannot cross authentication namespaces, and an opaque compaction cannot be discarded if it represents prior context. These failures leave the previous model and history active. The target must also support the conversation's required tool and image capabilities.

Instruction, advertised-schema, and authentication changes still require an explicit transition before native history can be replayed. Missing historical evidence is not reconstructed from today's configuration. Default editor model cycling remains removed.

Successful submission clears the composer. A rejected submission preserves the draft, shows a conversation error, and logs the failure. Rejection before request admission does not add another user entry. A failure after admission preserves the recorded prompt instead of discarding it.

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
