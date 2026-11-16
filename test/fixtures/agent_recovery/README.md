# Linux agent recovery corpus v0.1

Run `bash scripts/agent_recovery_baseline` from a checkout of the pinned corpus commit linked in the PR and baseline report.
The command boots the real headless Minga application and runs four deterministic recovery scenarios in new scratch Git repositories.
A failed scenario exits nonzero, including when the production behavior is already known to fail.
This is baseline infrastructure for #3441 and #3443, not completion of either issue or a release verdict.
See the dated [baseline report](BASELINE.md) for observed failures and sanitized raw evidence.

## Prerequisites

Use Linux with `/proc`, Unix-domain sockets, Python 3 with `os.pidfd_open` and `signal.pidfd_send_signal`, Git, and the repository's exact `.tool-versions` toolchain.
Install the repository's dependencies and Hex before running the command; the corpus does not fetch missing packages.
With asdf, the launcher resolves installed binaries before replacing HOME.
Without asdf, put the pinned toolchain binaries directly on PATH.
Missing tools, missing dependencies, startup failures and unavailable process observation fail explicitly, never skip.
If Hex is installed outside `$HOME/.mix/archives`, set `MIX_ARCHIVES` to that installation's archive directory.

The launcher removes the inherited environment and creates private HOME, XDG and temporary directories under a fresh `/tmp/minga-agent-recovery-*` directory.
It reuses the source checkout, installed toolchain, Hex archive installation and existing dependency/build caches, but does not load developer credentials or configuration.
It makes no real provider request, starts no gateway, changes no permissions and uses no privileged operation.
The only IPC endpoint created by the process fixture is a local Unix-domain socket.
Run corpus invocations serially because Mix shares the checkout's build cache.

## What the evidence proves

All prompts enter through `MingaAgent.Runtime`.
The real `Session`, Native provider, tool registry, durable effect admission, tool executor, shell Port, tool routing and artifact store execute normally.
`scripts/agent_recovery_provider.exs` replaces only Native's documented `llm_client` boundary with predetermined ReqLLM response chunks.
It does not replace Session or Editor state, substitute a tool implementation, or contact a model.
The fixture uses explicit response barriers and BEAM process monitors, not sleeps.
The Python observer waits on Linux pidfds, including for reparented descendants.
Its one-second cancellation deadline is an expectation, not a successful skip or a production timeout change.

| Scenario | Required outcome | Prohibited effect |
|---|---|---|
| Cancel descendants | Abort a running shell verification with a child; every owned process exits within one second | A surviving descendant or a write after cancellation |
| Delayed response | After a completed append and cancellation, deliver a response to the old transport consumer while its replacement is blocked; the replacement finishes | A second append or stale text in the replacement |
| Retained output | Shorten displayed shell output, then retrieve every retained page through the actual `fetch_output` tool; complete bytes and SHA-256 match the known fixture | Lost bytes, false completeness or replay of the output producer |
| Human edit | Prepare an existing-file whole-file replacement, change the scratch file as a human, then dispatch the prepared edit | Human bytes overwritten or an unreported stale-edit conflict |

The delayed-response case observes Native's cancellation of the old transport consumer and successful completion of the replacement.
It is not live-network evidence, a full request-ID adversarial matrix, or proof across application restart.
The human-edit case deliberately exercises the advertised `write_file` tool, without adding a revision check in the driver.
A missing production revision contract stays a failure owned by #3436.
The output expectation is full retention, not merely honest reporting of incomplete capture.
A capture-byte limit that loses known output stays a failure owned by #3432.
Process-tree cancellation belongs to #2843, with worker admission/scheduling owned by #2839.

## Reading a run

The launcher prints the evidence directory even when startup fails.
It never deletes failed attempts or scratch repositories.
`exit-status.txt` preserves the command result, `prerequisites.log` preserves preflight diagnostics, and `runtime.log` preserves startup and console output.
Successful startup adds `environment.json`, aggregate `results.json`, and one directory per scenario containing sanitized `events.ndjson`, `result.json`, the scratch repository, `repository.diff` and `repository.status`.
The output scenario also retains known, displayed and recovered bytes.
Each result records the expected repository result, prohibited effects, actual observations, human/cleanup interventions, elapsed time, artifact bytes, provider request count and surviving owned processes before and after cleanup.
Artifact bytes count scenario files before writing the result JSON, including the scratch Git metadata and persisted session evidence.
The raw event stream replaces the sandbox and source-checkout prefixes with `$SANDBOX` and `$SOURCE`.
Only deterministic fixture input and scratch content enter these logs.

The cancellation observer first records survivors without intervention.
If a child survives, it releases that child's explicit barrier to test whether the child can still write a sentinel.
It then sends SIGKILL through identity-safe pidfds to remaining owned processes and records that cleanup separately.
Cleanup is not recovery success.
The observer also performs cleanup in `finally` on control-channel failure, and the driver requests and awaits cleanup on its own error paths.
Append/output producers record their PID and Linux start identity before work; the driver checks that original process has exited without confusing a reused PID with an owned process.
The other scenarios issue only their specified fixture prompts, responses and human edit.

These are **non-live-model** runs.
Provider-reported fixture cost is zero because no request is billed, not because a live task used zero tokens.
Live-model token use, cost, peak retained memory and shipping-build performance are unmeasured.
Compaction, model transitions, full application restart, denied execution, GUI/TUI parity, real coding-task completion and comparison harnesses remain under the original #3441 gate.
No release tag or release publishing is part of this corpus.
