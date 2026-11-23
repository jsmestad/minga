# Agent model selection

Minga resolves every agent model choice to one exact route before it becomes active. The route records the backend, model identity, request provider, execution protocol, provider-facing model ID, reasoning controls, limits, and capabilities. Hosted routes also record the endpoint and credential profile. Prompt transport consumes that resolved route directly.

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

Custom inference servers, custom endpoints, and hosted provider endpoint overrides are not supported.

## Configure a model

On an Apple Intelligence-capable Mac running macOS 27 or later, open `/model` and choose **Apple Intelligence (On Device)**. This route uses the system model on the Mac running the Minga agent. It needs no API key or network endpoint. Minga checks availability when you open the picker but does not start inference or download a model. If the model is not ready, enable Apple Intelligence in System Settings as needed and reopen `/model`.

Apple Intelligence is currently available only in qualifying source builds. Official DMG and Homebrew builds do not include the helper. The normal native build includes it on Apple Silicon when the macOS 27 SDK is available. To build it explicitly, run `mix native.build.apple --require`.

To make it your configured model, set:

```elixir
set :agent_model, "apple:system"
```

An explicit configuration or a restored session keeps the exact Apple route. Minga checks readiness again before inference and does not switch to a hosted model if Apple Intelligence is unavailable. The route supports text and a compact file tool set: read, find, grep, edit, and write. Normal approvals still apply. It does not support image attachments, thinking controls, or history compaction. Apple cannot enforce every schema rule while it generates, such as a string length. When a tool call breaks its schema, Minga returns a tool error that names the failing field, and the model can retry in the same turn.

The on-device model has a 4,096-token context, which a large `AGENTS.md` can fill on its own. Minga counts the fixed prefix (instructions and tool schemas) with Apple's tokenizer when you select the route and before each prompt. Project instruction files, active skills, and the append prompt are sent only when they leave room for the conversation. When Minga leaves one out, the transcript says so; it never drops them silently. If the base instructions and tools alone cannot fit, `/model` refuses the route and shows Apple's counts.

When a prompt does not fit, Minga does not trim history. The refusal says whether the fixed prefix or the retained history and input are too large, with the token counts. Only the history case is helped by shortening the prompt or starting a new conversation. Tool results sent to Apple are limited to 2 KB; a longer result ends with a truncation marker, and the model can read further with `read_file` offset and limit.

Set a hosted provider and catalog model:

```elixir
set :agent_model, "anthropic:claude-sonnet-4-20250514"
```

Open **Models and connections** from the Agent workspace to configure a credential without sending your draft. Choose **Sign in with ChatGPT** to open browser authorization, or use `/login` for the same local flow. Until authorization finishes, **Cancel connection setup** cancels that attempt without removing existing credentials.

If your browser cannot open automatically, use **Open authorization link** or **Copy authorization link** in the picker. Approve the request, choose **Resume OpenAI sign-in**, then paste the redirect URL or code into the masked prompt. For an Agent workspace attached to another host, follow [the remote sign-in instructions](REMOTE_AGENTS.md#sign-in-on-a-headless-server).

For other providers, choose the API-key action, run `/auth <provider>`, or use the provider environment variable. Open `/model` to list the routes available for the configured credentials.

Once a listed model can be used, `/model` is for choosing a model. It lists the models, then one **Connect another provider…** row. Select that row to open the sign-in, API-key, route setup, and retry actions in a second picker; Escape returns to `/model` with your query and selection. A provider that a listed model already uses offers its account actions instead of a first sign-in: **Sign in to ChatGPT again** or **Sign out of ChatGPT**, and **Replace** or **Remove** for a stored API key. A key from an environment variable is not listed there, because it takes precedence over a stored key. A setup that is still in progress keeps its cancel, link, and resume rows in `/model`. Until a model can be used, every connection action stays in `/model` so first-run setup is one step.

For a Codex subscription, `/model` checks the signed-in account's model list. A model in OpenAI's API catalog is not automatically available through Codex OAuth. If the check fails, the picker explains why it omitted Codex models and still shows routes for configured API keys. Reopen `/model` to refresh the account list used by slash completion.

The picker groups models by route. Each route (for example, `ChatGPT` or `anthropic API`) is a section header with its models below it, so the route name is not repeated on every row. Each model row has a status chip, such as **Ready**, and a short description with the price for a metered route, the context limit, the thinking level, and any capability the model lacks. A subscription route's rows show the account or plan reset time first. When you type a query, the route with the best match comes first and a route with no matching model drops out with its header. The route name, the exact endpoint, and the credential profile stay searchable. Connection rows follow the models under their own headers.

Slash completion shows:

- model provider and wire protocol;
- hosted endpoint and canonical protocol path;
- secret-free credential profile;
- reasoning controls and context limit;
- tool, image, and streaming capability evidence; and
- favorite and current status.

A choice becomes active only after the current session validates the exact catalog route and credential. An unsupported provider, missing catalog model, unavailable credential, or incompatible capability returns an error and leaves the previous route active. Minga does not fall back to another model, provider, credential source, or endpoint.

## Saved selections

Credential values are never stored in the selection. API-key selections store only the provider and source (`env` or `file`). OpenAI Codex selections store the OAuth account identity and a hash of the source identity; the OAuth filesystem path remains request-local. The Apple system route explicitly records that it has no credentials.

Saved sessions persist the complete secret-free route snapshot. Restore validates the recorded backend, route, authentication, execution contract, and capabilities without substituting another route. A valid selection is not permission to replay retained native context with different inputs.

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
