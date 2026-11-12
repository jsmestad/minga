# Session Recovery

A saved session must resume from the model conversation that actually completed, not from a reconstruction of the visible transcript. Minga stores the lossless provider continuation beside the editable display history and restores both as one session snapshot.

## Completed turns

`MingaAgent.Session` owns two related records. The display transcript contains stable entry IDs, user-visible tool calls, thinking, usage, branches, and pins. The provider continuation contains the exact ReqLLM messages used for the next model request, including inline attachment bytes, grouped tool calls and results, reasoning details, and provider-native content.

After a turn completes, Session persists the continuation boundary, transcript, branch boundaries, pins, provider selection, usage, and memory snapshot together. Reopening the saved session restores that boundary. Collapsing tool output or thinking changes only the display transcript; it does not rewrite the next model request.

Adjacent native tool turns use the completed assistant ReqLLM message, not reconstructed display text. Ordered content, supported provider blocks and reasoning signatures, and the original tool-call group and IDs reach the next request through the selected transport's encoder. Text, thinking, tool progress, and usage are separate projections. A cancelled or malformed response is incomplete and never becomes a successful assistant turn.

Retained-output references and recovery bookkeeping stay in the durable history. The transient SDK request omits those host-only tool metadata fields after image hydration or unsupported-image projection, without removing provider-owned metadata. Tool arguments, result text, and filenames remain model-visible.

A branch can resume only from a recorded boundary. Branching from a display entry without a matching model boundary returns an error rather than guessing which provider messages belonged there. Switching branches restores the branch's messages and boundary identities together.

## Immutable request prefixes

Session's continuation owns an interned prefix store. Instructions and callback-free tool declarations are separate immutable components; an epoch joins their identities with the selected route and authentication evidence. The selected prefix also retains skill names, so a provider or runtime restart restores the selection without parsing historical prompt text or rewriting its immutable instructions. Requests, outcomes, tool checkpoints, boundaries, and branch snapshots reference that epoch. Display events report identity and status, not copies of the schema set.

Continuation codec version 4 stores each reachable component once. Dynamic declaration source owners are captured as durable binary identities before hashing, so an unloaded or removed extension cannot make its saved history undecodable; the changed live registry still requires an explicit transition. Versions 2 and 3 preserve their exact ReqLLM values, but missing historical prefix evidence remains unknown: today's prompt and registry cannot reconstruct it. Corrupt identities, digests, and dangling references are rejected. Branches retain their own references, and compaction keeps the provider's exact native window without prepending stored instructions.

Prefix changes require an idle request boundary with no unsettled tool group. Skill updates are previewed before effective mutation; a rejected transition or failed save leaves the last-good prefix and active skills unchanged. Unchanged turns and identical declarations reuse the same components and epoch. See [native replay identity](AGENT-MODEL-SELECTION.md#native-replay-identity) for restart and fresh-conversation requirements.

Native loop refusals retain their structured context-transition identity through Session presentation. Their public error directs the user to retain the saved record or use `/new`; it is not reported as a provider outage or model-picker failure, and does not expose arbitrary diagnostic text.

## Live tool authority

An advertised declaration is not an execution grant. Session authorizes each correlated call using current mode, restrictions, permissions, and approval policy. After approval and hook/advice delays, Registry resolves the current registration and Executor validates arguments, builds its callback, and starts it once.

The final gate reads versioned policy before Registry resolution and validates the same ETS incarnation and option revisions afterward. Equal-value writes, allow–deny–allow changes, resets, source removal, and registration replacement cannot reuse an old grant. Refusal is an ordinary saved tool result; storage failure instead blocks continuation. Work that already crossed the start gate may settle after revocation. Revocation does not interrupt an instruction or undo an external effect.

## Default context and optional packs

Automatic memory injection, the built-in memory-write tool, default introspection tools, model-cycling commands, and backend choice in the default child-agent tool have been removed. Legacy `pi_rpc` configuration is rejected rather than resolved to an executable provider. Project/global instructions, selected skills, existing memory files, saved history, registered providers, and Runtime/Gateway introspection remain owned by their existing sources.

After the runtime starts, opt in to read-only memory discovery with `MingaAgent.ToolPacks.Memory.register()` or introspection with `MingaAgent.ToolPacks.Introspection.register()`. These packs are not registered automatically. Notebook and todo tools/state remain available; only notebook-specific prompt instructions were removed here.

## Interrupted requests and tools

An interrupted provider request keeps its exact submitted prompt. The next continuation includes that prompt once; it does not replay a partial provider response.

Before an external tool effect starts, Session saves the assistant tool-call group and a single-attempt admission record. It saves each result before presenting that result as complete. During recovery:

- A call with a saved result remains complete and is not executed again.
- An admitted call without a saved result is marked indeterminate and is never run again automatically. If its exact delivery-key capture reached terminal storage before the process stopped, recovery attaches that retained `Output`; otherwise the result explicitly has no recovered output.
- A call without admission is marked not executed.
- The recovered tool exchange receives a resumable boundary, so later branch operations do not truncate or invent the reconciled result.

A failed checkpoint or result save blocks further model execution. Minga preserves the last durable continuation and reports the persistence failure instead of claiming the newer state can resume safely.

Managed Session restart also waits for the prior provider and every registered effect worker to exit. A new generation cannot overlap an effect from the previous generation. Stopping or exhausting restart attempts keeps the session ID reserved until the Session, provider, and workers are down. The ownership and generation contract is described in [Architecture](ARCHITECTURE.md#agent-conversation-persistence-and-recovery).

## Retained tool output

Tool results keep two separate facts: a bounded model-visible `view` and, when admitted, a record-scoped reference to the exact captured bytes. A complete capture, a requested range, presentation truncation, and an incomplete capture are distinct states. A visible truncation does not mean retained bytes were discarded, while an incomplete capture never claims that omitted bytes exist.

References are authorized to one durable session record. They survive compaction, Session process exit, and application restart because snapshots pin the union reachable from the transcript, same-record branches, and the complete provider continuation, including pending tool arguments. Candidate pins are installed before a snapshot rename. Definite pre-rename failures release only candidate pins; ambiguous post-rename failures preserve all possible owners until a synchronized save or load validates the durable JSON authority.

Delivery ownership transfers only after the renamed snapshot and its parent directory are durable. A failure to release an obsolete pin after that point is logged and leaves a conservative pin, not a false report that the committed save failed. Malformed, unreadable, or schema-invalid prior JSON blocks replacement and cannot authorize cleanup.

Explicit session deletion removes the record namespace. Unreferenced cleanup can remove only artifacts without a delivery, snapshot, or task pin. Missing, expired, corrupt, cross-record, and quota-refused references fail visibly; retrieval never reruns the producer or reads the source again.

Source-backed results also record the selected range and a content revision. Buffer, fork, changeset, and project-view reads use the captured in-memory generation. Disk and query revisions include a digest of captured content, so a same-size metadata-only change cannot masquerade as the same source. A fork that creates a new session record must quota-admit a bounded copy and rewrite every reference; it must not reuse the source record's tokens.

Requested disk line ranges stop reading once the selected range is complete; their total is `unknown` unless the capture actually observes EOF. Full unsaved-buffer and fork captures ask their owners only for a bounded prefix. Search results are captured once with their paths and match locations, including results beyond the visible page. Later retrieval reads that fixed result set, not a mixture of the old query and changed sources.

Byte pages are binary-safe: non-UTF-8 text slices and non-text media are presented as labeled base64 instead of being rejected. Capture bytes, disk usage, item count, and image bytes have finite budgets. A refused capture or retained prefix reports its resource limit explicitly; it does not claim complete success.

Shell execution has one timeout owner. A timeout retains the bounded bytes already produced as an incomplete timeout `Output`; it does not replace them with a generic timeout string.

Image bytes remain in the artifact store. Delivery requires two independent facts on the frozen [exact model selection](AGENT-MODEL-SELECTION.md#capability-policy): image input support and image tool-result transport support. Unsupported routes and formats return an explicit tool limitation before full source capture. Supported images are fetched in bounded pages and hydrated only into the transient SDK request. Saved continuations, exports, hooks, and gateway events carry reference facts, not retained image payload bytes. A corrupt or unauthorized image reference fails visibly; an unsupported restored image becomes a model-visible tool error without fetching its bytes.

The combined snapshot format is version 5. It reads historical model-selection versions 3 and 4 only when they contain no retained output, and reads historical retained-output version 3 only when its generation authority is present and model-route fields are absent. Hybrid version-3 records are rejected. The next save writes the combined format.

Run capture and restore in separate BEAM processes to exercise storage, source changes, compaction, and application restart:

```sh
root=$(mktemp -d "$PWD/../retained-output-smoke.XXXXXX")
MIX_ENV=prod mix run scripts/retained_output_smoke.exs capture "$root"
MIX_ENV=prod mix run scripts/retained_output_smoke.exs restore "$root"
```

Retained-image projection and exact SDK encoding are covered by the Native adapter/output-hydration tests. A loopback encoder fixture does not qualify a vendor route for retained native replay; that requires the exact-route prefix/restart conformance proof.

## Older display-only records

Older records do not contain enough information to recreate every provider request. They remain unchanged until the user explicitly imports them. Import preserves the source record and marks the new continuation as `legacy_reconstructed`.

The importer rebuilds only portable user and assistant text. It does not invent missing attachment bytes, provider signatures, or tool results. Tool and system entries remain readable in the imported display history but are not sent as model history. The imported provenance stays visible so callers can distinguish reconstructed text from a lossless continuation.

## Application restart

A completed session snapshot is durable across a full application restart. The manager does not recreate volatile sessions automatically; opening a saved session starts its registration and loads the saved ID and continuation before the next prompt is sent. The next provider request begins with the saved messages followed by the new user prompt.

An application restart does not make an admitted effect safe to replay. If the snapshot contains an unfinished admitted effect, recovery records its unknown outcome and requires reconciliation. Use the visible tool result and the external system's state to decide what to do next.

For architecture ownership, see [Architecture](ARCHITECTURE.md#agent-conversation-persistence-and-recovery). For the provider request contract, see [For AI Coders](FOR-AI-CODERS.md#provider-turns-keep-their-durable-continuation).
