# Session Recovery

A saved session must resume from the model conversation that actually completed, not from a reconstruction of the visible transcript. Minga stores the lossless provider continuation beside the editable display history and restores both as one session snapshot.

## Completed turns

`MingaAgent.Session` owns two related records. The display transcript contains stable entry IDs, user-visible tool calls, thinking, usage, branches, and pins. The provider continuation contains the exact ReqLLM messages used for the next model request, including inline attachment bytes, grouped tool calls and results, reasoning details, and provider-native content.

After a turn completes, Session persists the continuation boundary, transcript, branch boundaries, pins, provider selection, usage, and memory snapshot together. Reopening the saved session restores that boundary. Collapsing tool output or thinking changes only the display transcript; it does not rewrite the next model request.

A branch can resume only from a recorded boundary. Branching from a display entry without a matching model boundary returns an error rather than guessing which provider messages belonged there. Switching branches restores the branch's messages and boundary identities together.

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

The loopback image smoke sends a valid PNG larger than one fetch page through the actual Native/ReqLLM Anthropic encoder and checks exact decoded wire bytes. Its second route refuses image tool-result transport and must send an explicit error with no wire image. It uses a temporary loopback-only API key, not a vendor account:

```sh
mix run scripts/smoke_native_retained_image.exs
```

The optimized benchmark emits JSON with p50/p95 capture-to-visible timings for sub-cap, ten-times-visible-cap, and quota-crossing fixtures; warm and reopened-actor late-page retrieval; scoped `:file.pread/3` requested-byte counts; sampled producer, store, and quota process-memory deltas; logical retained disk bytes and file count; fixture identities; and same-fixture legacy truncation/search baselines. Reopened actors do not flush the operating system's page cache. Memory is sampled every millisecond, so shorter allocation spikes may be missed.

```sh
MIX_ENV=prod mix run bench/agent_retained_output_bench.exs /path/to/repository
```

## Older display-only records

Older records do not contain enough information to recreate every provider request. They remain unchanged until the user explicitly imports them. Import preserves the source record and marks the new continuation as `legacy_reconstructed`.

The importer rebuilds only portable user and assistant text. It does not invent missing attachment bytes, provider signatures, or tool results. Tool and system entries remain readable in the imported display history but are not sent as model history. The imported provenance stays visible so callers can distinguish reconstructed text from a lossless continuation.

## Application restart

A completed session snapshot is durable across a full application restart. The manager does not recreate volatile sessions automatically; opening a saved session starts its registration and loads the saved ID and continuation before the next prompt is sent. The next provider request begins with the saved messages followed by the new user prompt.

An application restart does not make an admitted effect safe to replay. If the snapshot contains an unfinished admitted effect, recovery records its unknown outcome and requires reconciliation. Use the visible tool result and the external system's state to decide what to do next.

For architecture ownership and the measured continuation costs, see [Architecture](ARCHITECTURE.md#agent-conversation-persistence-and-recovery). For the provider request contract, see [For AI Coders](FOR-AI-CODERS.md#provider-turns-keep-their-durable-continuation).
