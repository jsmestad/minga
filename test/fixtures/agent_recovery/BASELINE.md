# Linux recovery baseline, 2026-11-16

**The runtime fails three of four deterministic recovery scenarios.**
This is non-live-model evidence, not a passing #3441 gate, completion of #3443, GUI parity evidence or a v0.1 release qualification.
No production code was changed and no expectation was relaxed.

## Reproduction and provenance

Run `bash scripts/agent_recovery_baseline` from the pinned corpus revision linked by [PR #3579](https://github.com/jsmestad/minga/pull/3579).
The [runbook](README.md) lists prerequisites, boundaries and allowed actions.
The production baseline is `203a58731f9a57bd5645b67ff13a324d02766fed`.
The compact [results manifest](baseline.json) records fixture hashes, expected repository results, prohibited effects, actual observations, interventions, timings, artifact bytes, process observations and validation receipts.

The run used Linux `7.3.4-ogc6.1.fc45.x86_64`, Elixir `1.20.5`, OTP `29.1.2`, ERTS `17.1.1`, four schedulers and warm dependency/build caches.
This was `MIX_ENV=dev`, not a shipping-build performance measurement.
Synthetic OAuth selected the existing Codex replay contract; predetermined ReqLLM chunks entered only at the external `llm_client` boundary.
No live model request was made.
Live-model tokens, cost, peak retained memory and comparison-harness results were not measured.

## Observed results

| Scenario | Result | Elapsed ms | Fixture requests | Artifact bytes | Owned survivors before cleanup | After cleanup |
|---|---|---:|---:|---:|---:|---:|
| Cancel descendants | FAIL | 3904.444 | 1 | 56622 | 2 | 0 |
| Delayed response | PASS | 122.987 | 3 | 63332 | 0 | 0 |
| Retained output | FAIL | 154.025 | 3 | 941814 | 0 | 0 |
| Human edit | FAIL | 83.279 | 3 | 65101 | 0 | 0 |

Cancellation leaves both verification workers alive after the one-second deadline.
Releasing the surviving child's explicit barrier writes `late-effect.txt` after cancellation.
Subsequent pidfd cleanup stops both workers; cleanup is not recovery success.
Owners: [#2843](https://github.com/jsmestad/minga/issues/2843) and [#2839](https://github.com/jsmestad/minga/issues/2839).

Delayed-response recovery preserves exactly one completed append and produces the exact replacement assistant response without stale text.
This proves the exercised Native transport-consumer cancellation path, not every request-ID/event combination or live-network behavior.

Retained-output recovery returns only 51200 of 135168 known bytes.
The runtime honestly marks capture incomplete, but the recovered hash differs from the fixture hash and 83968 bytes remain unavailable.
Owner: [#3432](https://github.com/jsmestad/minga/issues/3432).

The prepared whole-file write replaces the later human version on both disk and buffer, reports success and exposes no conflict.
Owner: [#3436](https://github.com/jsmestad/minga/issues/3436).

Elapsed time includes scenario startup and Session cleanup, but excludes application startup and initial compilation.
Artifact bytes include scenario-local persisted sessions and scratch Git metadata before writing the result JSON.
The cancellation case observes both workers through pidfds; append/output producers record their PID/start identity and are observed absent after completion.
The file-only case creates no external command workload.
Session shutdown and cancellation of the old transport consumer are monitored.

## Raw evidence

Generated logs, output dumps, scratch snapshots and failed attempts are retained in one [external evidence archive](https://gist.github.com/breznknecht/9eeafac975ba8a4a13676ab37857f8ca), not as repository fixtures.
The manifest pins the exact download URL and decoded archive SHA-256: `b26f22873012a10eb228c23d7b4fd326be8cf13fe8607b7d2914ed9c0927e1e7`.
The archive contains 231 original sanitized files, including every retained failed attempt and repository-gate log.
Archive paths are rooted at `2026-11-16/`; final observations are in `baseline-05/`, earlier attempts in their named directories, and validation receipts/logs in `validation/`.

To download, verify and extract the archive from this directory:

```bash
curl -fsSL "$(jq -r .raw_evidence.url baseline.json)" | base64 -d > /tmp/minga-recovery-evidence.tar.gz
printf '%s  %s\n' "$(jq -r .raw_evidence.sha256 baseline.json)" /tmp/minga-recovery-evidence.tar.gz | sha256sum -c -
mkdir -p /tmp/minga-recovery-evidence
tar -xzf /tmp/minga-recovery-evidence.tar.gz -C /tmp/minga-recovery-evidence
```

Failed attempts remain evidence, not alternative passing baselines.
They include missing Hex, the prototype observer's incorrect ancestor ownership, refusal of an unqualified replay route, later assertion/process-observation corrections, and test-discovery warnings.
The observer EOF probe failed visibly, cleaned both workers and created no sentinel.
An invalid inherited Git-configuration probe still pinned the correct source revision.

## Validation and remaining scope

The focused autosave module passed eight tests after its three conflict cases were changed to arm the timer after the external mutation, with assertions unchanged.
The required local `MIX_ARCHIVES="$HOME/.mix/archives" make done` passed in 143.82 seconds.
The manifest retains tested-source hashes and command receipts; raw logs remain in the external archive.

Both #3441 and #3443 remain open.
Real coding tasks, repeated live-model measurements, compaction, restart, model transitions, unresolved decisions, denied execution, GUI/TUI parity, shipping-build performance, comparison runs and the final integrated verdict remain required.
No release tag or release publishing occurred.
