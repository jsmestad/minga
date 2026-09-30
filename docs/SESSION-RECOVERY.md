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
- An admitted call without a saved result is marked indeterminate. Its effect may have completed before the process stopped, so Minga never runs it again automatically.
- A call without admission is marked not executed.
- The recovered tool exchange receives a resumable boundary, so later branch operations do not truncate or invent the reconciled result.

A failed checkpoint or result save blocks further model execution. Minga preserves the last durable continuation and reports the persistence failure instead of claiming the newer state can resume safely.

Managed Session restart also waits for the prior provider and every registered effect worker to exit. A new generation cannot overlap an effect from the previous generation. Stopping or exhausting restart attempts keeps the session ID reserved until the Session, provider, and workers are down. The ownership and generation contract is described in [Architecture](ARCHITECTURE.md#agent-conversation-persistence-and-recovery).

## Older display-only records

Older records do not contain enough information to recreate every provider request. They remain unchanged until the user explicitly imports them. Import preserves the source record and marks the new continuation as `legacy_reconstructed`.

The importer rebuilds only portable user and assistant text. It does not invent missing attachment bytes, provider signatures, or tool results. Tool and system entries remain readable in the imported display history but are not sent as model history. The imported provenance stays visible so callers can distinguish reconstructed text from a lossless continuation.

## Application restart

A completed session snapshot is durable across a full application restart. The manager does not recreate volatile sessions automatically; opening a saved session starts its registration and loads the saved ID and continuation before the next prompt is sent. The next provider request begins with the saved messages followed by the new user prompt.

An application restart does not make an admitted effect safe to replay. If the snapshot contains an unfinished admitted effect, recovery records its unknown outcome and requires reconciliation. Use the visible tool result and the external system's state to decide what to do next.

For architecture ownership and the measured continuation costs, see [Architecture](ARCHITECTURE.md#agent-conversation-persistence-and-recovery). For the provider request contract, see [For AI Coders](FOR-AI-CODERS.md#provider-turns-keep-their-durable-continuation).
