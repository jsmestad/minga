# First Agent open after launch

Receipt for [#3610](https://github.com/jsmestad/minga/issues/3610). In the shipping macOS app, a cold `SPC a n` or `SPC a a` shows the composer about 3.0 s after the final key (p50; p95 3.6 to 6.8 s). The first model catalog load is 82% to 93% of that wait in every cold open. Since #3674 the catalog loads off the Editor, so the Editor is no longer frozen for those seconds, but the open still waits for the load before it creates the tab, and then blocks the Editor for another 265 ms (p50) while the session starts. A later open in the same run blocks the Editor for 194 ms. The app then takes 60 to 150 ms to present the first Agent frame. Nothing here is near the proposed 50 ms target.

The decision is Gate B, a non-blocking start request, with the composer shown before the catalog load finishes and the Ingest subscription moved into `Session.init/1`. See [Decision](#decision).

## After #3934

The fix ([#3934](https://github.com/jsmestad/minga/issues/3934), with [#3641](https://github.com/jsmestad/minga/issues/3641)) meets the 50 ms target. A cold `SPC a n` or `SPC a a` right after launch now writes the frame with the Agent tab and composer, in the starting state, 11 to 15 ms after the final key at p50 and 22 to 24 ms at p95. The open command spends under 2 ms in the Editor. Send becomes ready when the provider attaches: about 105 to 160 ms after the key once the launch preload has finished, and 2.4 s when the open arrives while the preload is still running.

Build: commit `3692c0429614ab6b2c732491c9a14445d3aba4f8` (this branch before it was rebased onto #3937, which changed only the macOS sidebar layout; the BEAM code matches `a0e6b29b0`), assembled with `MIX_ENV=prod mix app.assemble`, main binary SHA-256 `29718541dc905b468241db6f67d760f0b6f384dc5c1bee4a01953bd239845549`. Same machine, OS and fixture as below: Apple M1, 16 GB, macOS 27.2 (26B123). 20 launches per first-open cell and 40 later opens per command, no failed launches. Raw samples are in `bench/agent_first_open/after/`; `scripts/agent_first_open/summarize.py bench/agent_first_open/after/matrix` reproduces the tables.

### Before and after

Composer frame written, ms from the final key-down, p50 / p95:

| Command | Condition | Before (#3610), receipt attribution | After, receipt attribution | After, corrected attribution |
|---|---|---|---|---|
| SPC a n | immediate | 3,045.4 / 3,586.7 | 29.1 / 41.3 | 12.6 / 23.8 |
| SPC a n | first open 10 s after launch | 3,024.5 / 6,806.0 | 29.0 / 38.4 | 14.3 / 20.7 |
| SPC a n | later open, same run | 210.3 / 290.7 | 24.8 / 37.3 | 13.4 / 19.9 |
| SPC a a | immediate | 3,049.1 / 4,147.2 | 24.9 / 38.9 | 11.1 / 21.6 |
| SPC a a | first open 10 s after launch | 3,051.1 / 4,499.6 | 25.8 / 36.6 | 12.1 / 20.4 |
| SPC a a | later open, same run (reopen) | 27.6 / 39.5 | 29.6 / 37.0 | 12.9 / 20.1 |

**Attribution fix.** The #3610 driver took the first port write after the composer frame's render span *ended*. The renderer writes a frame inside its own span, so that was the next frame's write, often 10 to 20 ms later. `measure.py` now takes the first write after the render *began*, which is the composer frame's own write. It still records the old attribution (`composer_emit_receipt_attribution_ms`) so the before column compares like for like; the before raw samples cannot be recomputed because their traces were not committed. The target holds under both.

Other endpoints, p50 / p95:

| Command | Condition | Composer presented (app), before → after | Send-ready frame written, before → after |
|---|---|---|---|
| SPC a n | immediate | 3,189.9 / 3,752.8 → 190.5 / 214.1 (n=17) | 3,045.4 / 3,586.7 → 2,418.4 / 2,450.7 |
| SPC a n | first open 10 s after launch | 3,157.7 / 6,987.0 → 194.9 / 215.6 | 3,024.5 / 6,806.0 → 152.1 / 164.9 |
| SPC a n | later open, same run | 305.8 / 422.5 → 126.1 / 160.1 | 210.3 / 290.7 → 105.8 / 116.3 |
| SPC a a | immediate | 3,187.4 / 4,334.6 → 190.5 / 214.4 (n=16) | 3,049.1 / 4,147.2 → 2,417.8 / 2,466.8 |
| SPC a a | first open 10 s after launch | 3,181.4 / 4,672.4 → 182.4 / 199.6 | 3,051.1 / 4,499.6 → 157.6 / 167.7 |
| SPC a a | later open, same run (reopen) | 84.2 / 99.3 → 86.3 / 96.3 | 27.6 / 39.5 → 12.9 / 20.1 |

Seven immediate opens have no presented time because the app reported no presentation for that frame sequence within the driver's 1 s window; their BEAM endpoints are complete. Send-ready is BEAM-side: the first frame written after the provider attached. The app disables Send until the conversation is live.

### Where the time goes now

| Stage, p50 / p95 ms | SPC a n immediate | SPC a n 10 s | SPC a n later | SPC a a immediate | SPC a a 10 s |
|---|---|---|---|---|---|
| Open command in the Editor | 0.4 / 1.5 | 0.3 / 0.4 | 0.4 / 0.5 | 0.5 / 0.7 | 0.2 / 0.4 |
| `tab_switch` | 0.2 / 1.1 | 0.2 / 0.2 | 0.2 / 0.3 | 0.2 / 0.3 | 0.1 / 0.2 |
| `ensure_configured_model` | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 |
| Key post to BEAM dispatch | 6.0 / 17.3 | 9.4 / 16.7 | 10.3 / 16.3 | 5.2 / 15.6 | 7.4 / 15.5 |
| `session_manager_start` (manager) | 83.3 / 86.9 | 105.5 / 108.3 | 57.0 / 58.8 | 85.6 / 90.7 | 105.8 / 112.2 |
| `session_model_resolve` (session) | 76.7 / 79.7 | 97.8 / 101.0 | 51.3 / 52.8 | 76.9 / 82.4 | 97.1 / 100.6 |
| `session_subscribe` (session init) | 0.1 / 0.1 | 0.1 / 0.1 | 0.0 / 0.0 | 0.0 / 0.1 | 0.1 / 0.1 |
| `provider_start` (session) | 27.6 / 28.5 | 28.3 / 29.4 | 30.7 / 32.6 | 27.4 / 28.6 | 28.7 / 29.9 |
| `session_start_hook_config` (hook task) | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.1 |
| App: composer presented minus written | 176.6 / 189.4 | 177.2 / 194.9 | 112.3 / 146.2 | 176.4 / 193.3 | 169.3 / 177.6 |

- **Nothing on the first-frame path waits for the session.** The open command installs the tab and composer and sends one `:gen_server.send_request/2`; `tab_switch` is 0.2 ms on a first open (was 11 to 14 ms) because `MingaEditor.LaunchWarmup` loads the editor's modules in the background after the first frame (0.35 to 0.47 s, low priority). In interactive release mode the first open used to load and JIT-compile about 36 modules inside the Editor.
- **The catalog loads once, before the user asks.** `MingaAgent.ModelCatalog` starts the load when the first frame is dispatched. An open that arrives during it joins that load instead of starting a second one; two concurrent loads had serialized on `llm_db`'s `:global` lock, whose retry backoff added 1.2 to 2.6 s. `catalog_load` does not appear in the open windows above because it started before the final key.
- **Session start no longer blocks the Editor or Ingest**, and Ingest attaches inside `Session.init/1` (`session_subscribe` 0.1 ms, in the session). The Editor makes no call into the new session.
- **Remaining cost, off the Editor:** `session_model_resolve` is still 51 to 98 ms. The cached catalog index halved it in a dev VM (28 to 14 ms per resolve), but resolving the default model still builds candidate intents over the whole catalog. It runs inside `SessionManager.start_session`, so it delays send-ready and other manager callers, not the Editor. A later change could cache the resolved default per catalog epoch and credential snapshot.
- **The app still takes 110 to 190 ms to present the first Agent frame** (#3935, out of scope here).

### SessionStart hook that runs a shell command

Same `sleep 0.5` hook as below, `SPC a n immediate`, 5 launches with 4 later opens each (raw samples in `bench/agent_first_open/after/hook/`). The hook still runs about 570 ms (p50 570.3, max 587.8, n=25), now in its own task:

| Measure | Before: cold p50 / p95 (n=5) | Before: later p50 / p95 (n=20) | After: cold p50 / p95 (n=5) | After: later p50 / p95 (n=20) |
|---|---|---|---|---|
| Composer frame written | 3,870.2 / 3,973.1 | 760.6 / 792.5 | 15.0 / 22.2 | 13.1 / 18.3 |
| Send-ready frame written | | | 2,431.0 / 2,472.9 | 103.5 / 113.7 |
| Editor blocked (open command) | 861.6 / 869.8 | 744.2 / 771.8 | 0.3 to 0.6 | 0.2 to 0.6 |

The hook no longer delays the Editor, Ingest, or provider readiness.

The sections below are the original #3610 receipt, unchanged.

## What was measured

Build: commit `587e3df5aa3643a634647d8f04a2a6e1cf4da32a` (this branch: `main` at `2a40ec83e` plus the telemetry spans below), assembled with `MIX_ENV=prod mix app.assemble` (Release Swift build, prod BEAM release). Main binary SHA-256 `7a83dfb832554fa167d5dfe974cf9a3cfbfe75dfe65c71d3328c2443ebede767`. Machine: Apple M1 (4 performance and 4 efficiency cores), 16 GB, macOS 27.2 (26B123), Xcode 27.2. Other processes were running (several Expert language servers), as on a normal workstation.

Endpoints, all in milliseconds from the moment the final key-down was posted to the app:

| Endpoint | Side | Definition |
|---|---|---|
| Composer frame written | BEAM | Port write of the first frame whose render started after the open installed the Agent chat. That frame carries the composer. |
| Composer frame presented | App | Metal `presentedTime` of that same frame sequence, from the app's opt-in startup probe (`MINGA_STARTUP_TIMER=1`). |
| Send-ready frame written | BEAM | Port write of the first frame rendered after both the Editor installed the new session and the session finished attaching its provider. |

Send-ready equals the composer frame in every sample. The Editor's subscribe call already waits for the provider attachment (see [Stages](#stages)), and the snapshot the Editor installs afterwards carries `provider_phase: :running`, which `prompt_readiness/3` maps to `:ready`. This is BEAM-side; the app's Send button state was not observed.

Conditions, one launch per sample:

| Condition | Sequence |
|---|---|
| `immediate` | The reported sequence: keys posted as soon as the app presents its first frame after launch. |
| `later-first` | First open 10 s after the first frame. |
| `later-same-run` | After the first open, `Esc SPC a a` returns to the file, then the same keys again. For `SPC a n` this starts a second session; for `SPC a a` it reopens the existing one. |

20 launches per first-open cell and 40 later opens per command. Percentiles are nearest-rank over raw samples.

### Method

`scripts/agent_first_open/measure.py` launches the app through Launch Services (`open -n`) with a private `HOME` and XDG profile, opening one fixture file with `--editor`, and the same offline provider fixture as the #3644 terminal driver: a fake `OPENAI_API_KEY` and proxies pointed at `127.0.0.1:1`, so no request leaves the machine. `post_keys.swift` posts real key events to the app process with `CGEventPostToPid`, so they travel the app's normal input path, and records the wall-clock time of each key-down.

The profile's `config.exs` is `scripts/agent_first_open/trace_config.exs`. It attaches one telemetry handler that sends each listed event to a writer process, which appends one JSON line with the OS wall clock. The driver and the BEAM share that clock. Metal presentation times use the mach uptime clock and are converted with an offset sampled by the driver.

`scripts/agent_first_open/summarize.py bench/agent_first_open/matrix` reproduces every table below from the committed raw samples. Per-launch BEAM traces and app stderr (about 4 MB) were kept in the measuring session's scratch directory, not committed.

Probe cost: each span costs about 100 ns, and the handler sends one message per event, about 100 to 200 events per open. That is microseconds against a run-to-run spread of tens of milliseconds. The trace config also adds the time to evaluate one config file at boot, before the first frame.

One launch failed: the third key of a cold `SPC a a` (run 13) never reached the BEAM, so the open never happened. The driver retried the launch; the failure is in `bench/agent_first_open/matrix/failures.ndjson`. It is the only dropped key in 241 opens.

## Results

### Endpoints

| Command | Condition | n | Composer frame written p50 / p95 | Composer frame presented p50 / p95 | Send-ready frame written p50 / p95 |
|---|---|---:|---|---|---|
| SPC a n | immediate | 20 | 3,045.4 / 3,586.7 | 3,189.9 / 3,752.8 | 3,045.4 / 3,586.7 |
| SPC a n | later-first | 20 | 3,024.5 / 6,806.0 | 3,157.7 / 6,987.0 | 3,024.5 / 6,806.0 |
| SPC a n | later-same-run | 40 | 210.3 / 290.7 | 305.8 / 422.5 | 210.3 / 290.7 |
| SPC a a | immediate | 20 | 3,049.1 / 4,147.2 | 3,187.4 / 4,334.6 | 3,049.1 / 4,147.2 |
| SPC a a | later-first | 20 | 3,051.1 / 4,499.6 | 3,181.4 / 4,672.4 | 3,051.1 / 4,499.6 |
| SPC a a | later-same-run | 40 | 27.6 / 39.5 | 84.2 / 99.3 | 27.6 / 39.5 |

Waiting 10 s does not help: nothing loads the catalog before the first open, so `later-first` matches `immediate`. The `later-first` p95 of 6.8 s comes from one slow catalog load (5.9 s); the p50 is unaffected.

### Stages

p50 / p95 per open, in milliseconds. Spans in the Editor process unless marked. Blank cells did not run in that condition.

| Stage | SPC a n immediate | SPC a n later-first | SPC a n later-same-run | SPC a a immediate | SPC a a later-first | SPC a a later-same-run |
|---|---|---|---|---|---|---|
| `catalog_load` (effect worker) | 2,737.8 / 3,192.3 | 2,729.1 / 5,905.0 |  | 2,723.8 / 3,541.5 | 2,728.9 / 3,731.4 |  |
| `tab_switch` | 13.6 / 19.8 | 13.8 / 50.5 | 0.2 / 0.3 | 10.9 / 16.8 | 11.8 / 38.2 |  |
| `start_agent_session` (whole Editor start) | 251.7 / 359.6 | 252.2 / 515.6 | 193.6 / 276.9 | 252.5 / 361.2 | 260.8 / 378.7 |  |
| `ensure_configured_model` | 59.7 / 91.7 | 59.3 / 115.6 | 49.0 / 72.7 | 60.0 / 79.1 | 59.7 / 103.5 |  |
| `project_view_overlay` | | | | | | |
| `session_manager_start` | 99.8 / 153.6 | 97.5 / 200.7 | 73.5 / 104.2 | 98.2 / 124.5 | 104.0 / 148.9 |  |
| `session_init` (session) | 80.8 / 123.2 | 81.0 / 142.3 | 68.3 / 97.1 | 81.9 / 101.8 | 82.6 / 117.6 |  |
| `session_model_resolve` (session, inside init) | 61.7 / 93.8 | 61.6 / 92.3 | 67.9 / 96.5 | 61.6 / 67.8 | 61.6 / 66.7 |  |
| `session_subscribe` | 93.9 / 112.4 | 96.0 / 206.4 | 70.4 / 107.8 | 94.2 / 127.2 | 97.5 / 124.9 |  |
| `provider_project_view_refresh` | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 | 0.0 / 0.1 | 0.0 / 0.0 |  |
| `session_snapshot_read` | 0.0 / 0.1 | 0.0 / 0.1 | 0.0 / 0.1 | 0.0 / 0.1 | 0.0 / 0.1 |  |
| `provider_start` (session) | 57.4 / 70.4 | 59.7 / 131.8 | 39.8 / 61.5 | 57.8 / 70.5 | 60.2 / 80.5 |  |
| `session_start_hooks` (session) | 35.0 / 42.9 | 34.8 / 39.5 | 30.8 / 47.4 | 34.4 / 46.1 | 34.8 / 48.1 |  |
| `session_start_hook_config` (session, inside hooks) | 31.8 / 38.8 | 31.7 / 34.3 | 30.7 / 47.0 | 31.5 / 42.1 | 32.1 / 44.7 |  |
| Editor blocked (`tab_switch` + `start_agent_session`) | 264.5 / 379.4 | 265.4 / 566.1 | 193.8 / 277.1 | 265.3 / 378.0 | 275.1 / 421.4 | 0.2 / 0.2 |
| Subscribe time spent while the session ran provider start and hooks | 91.6 / 108.7 | 94.0 / 195.3 | 70.3 / 107.6 | 91.7 / 122.7 | 94.8 / 120.4 |  |
| App: composer presented minus written | 141.3 / 163.6 | 138.2 / 163.1 | 92.6 / 119.7 | 147.1 / 187.3 | 145.1 / 172.8 | 59.3 / 75.4 |
| Key post to BEAM dispatch | 17.8 / 49.2 | 7.9 / 77.9 | 9.1 / 17.2 | 28.5 / 58.9 | 8.9 / 31.4 | 8.2 / 16.9 |

`project_view_overlay` never ran: the fixture project has no project view to overlay. The open command itself returns in 5 to 6 ms on a cold open, because `CatalogStartup` defers the action. Launch to first presented frame: p50 1,561 ms, p95 3,159 ms (n=81).

### SessionStart hook that runs a shell command

A second run installed one SessionStart hook, `sleep 0.5`, and otherwise matched `SPC a n immediate` (5 launches, 4 later opens each; raw samples in `bench/agent_first_open/hook/`).

| Measure | Cold open p50 / p95 (n=5) | Later open p50 / p95 (n=20) |
|---|---|---|
| Composer frame written | 3,870.2 / 3,973.1 | 760.6 / 792.5 |
| `session_start_hooks` | 606.8 / 610.2 | 598.8 / 603.7 |
| `session_subscribe` | 673.1 / 674.5 | 640.5 / 645.2 |
| Editor blocked | 861.6 / 869.8 | 744.2 / 771.8 |

## Attribution

**The first catalog load dominates.** `catalog_load` is 2.72 to 2.74 s at p50 and 82.0% to 92.7% of the composer-frame time in all 80 cold opens (p50 89.6%). It runs in an effect worker, so the Editor keeps handling keys and shows "Loading Agent model catalog…". But `CatalogStartup.continue/2` defers the whole action, including creating the Agent tab, so no composer appears until the load ends. On this M1 the load takes about 2.7 s; the ticket measured 2.1 s on an M3 Pro.

**After the load, the Editor is blocked for 265 ms (p50) on a cold open and 194 ms on a later open.** Within `start_agent_session`:

- `session_manager_start`: 98 to 104 ms cold, 74 ms later. Most of it is `session_init`, and most of that is `session_model_resolve` (62 to 68 ms), which builds the catalog index over all models on every session start, not only the first.
- `session_subscribe`: 94 to 98 ms cold, 70 ms later.
- `ensure_configured_model`: 60 ms cold, 49 ms later. This is the Editor-process catalog walk that #3641 owns.
- `tab_switch`: 11 to 14 ms on the first open, 0.2 ms afterwards.
- `provider_project_view_refresh` and `session_snapshot_read`: under 0.1 ms.

**The Editor's calls into the new session do wait behind provider startup, but only the first one.** The subscribe call spends 92 to 95 ms (cold) and 70 ms (later) of its 70 to 98 ms while the session runs `provider_start` (57 ms cold, 40 ms later) and `session_start_hooks` (35 ms). Nearly all the subscribe time is that wait. The provider project-view refresh and the snapshot read arrive after the queue has drained and take under 0.1 ms. The native provider starts in 40 to 60 ms, not the 700 ms that `config/test.exs` assumes.

**Hook dispatch blocks on the hooks' shell commands, and the Editor waits with it.** With no hooks configured, `session_start_hooks` is 31 to 35 ms, and 31 to 32 ms of that is `session_start_hook_config`: `AgentConfig.resolve/0` computes the default model eagerly, which walks the catalog, just to read `.agent_hooks`. That happens on every hook dispatch, not only at session start. With one `sleep 0.5` hook, `session_start_hooks` is 600 ms and the Editor's subscribe call waits 640 to 673 ms. `CommandRunner` waits up to each hook's `timeout_ms` (default 30 s) plus a 1 s guard, so a slow hook can hold the Editor for that long.

**Ingest batch flushing stalls during the subscribe.** `Ingest.subscribe_session/3` makes the `Session.subscribe/4` call inside the Ingest process, so Ingest handles nothing else while the call waits: 70 to 98 ms (p50) with no hooks, about 650 ms with the 0.5 s hook. That figure is the Editor-side subscribe span; Ingest has no span of its own. Batches for other sessions are delayed by that time.

**The app adds 60 to 150 ms to show the first Agent frame.** Composer presented minus written is 141 to 147 ms on a cold open, 93 ms on a later `SPC a n`, and 59 ms when `SPC a a` reopens an existing session (BEAM write at 28 ms). The frame that returns to the editor view takes 74 ms p50 (45 to 119 ms, n=40) from write to presentation, so switching views is expensive in the app regardless of the Agent session. No BEAM change alone reaches 50 ms to a presented composer.

## Keys typed while the Agent tab opens

Today, there are two phases:

1. During the catalog load (about 2.7 s), the Editor is idle and the screen still shows the file. Keys are handled there, in the context the user sees. An `n` repeats the last search.
2. During the synchronous start (about 265 ms), the Editor is blocked. Keys queue in its mailbox and run after the open has switched to the Agent tab in Insert mode, so they are typed into the composer although the user typed them at the file. This is the reported `nn`.

The second phase is the misdirection. The first is correct but slow.

## Decision

**Select Gate B, a non-blocking start request, with Gate C's additions.** "No change" is not available: the composer takes 3.0 s p50 and 3.6 to 6.8 s p95 on a cold open, and the Editor still blocks for 194 to 265 ms per open, which is long enough to misdirect keys.

How the gates apply:

- **Gate A** (remove the Editor's waits on the new session) is not enough by itself. The Editor command remaining after `session_manager_start` is about 150 ms cold and 120 ms later, mostly the subscribe wait and `ensure_configured_model`, so the condition holds. But Gate A leaves `session_manager_start` (74 to 104 ms) in the Editor and does nothing for the 2.7 s catalog load, which dominates every cold open.
- **Gate B** holds: `session_manager_start` alone is 74 to 104 ms at p50, above the target.
- **Gate C** holds: the catalog load is 82% to 93% of every cold open. Gate C selects Gate B with its additions.

The implementation ticket should require all of the following, plus the constraints already in the Developer Notes (`:gen_server.send_request` with the reply monitor owned by the Editor, the pending start is not "no session", capture root and project view at command time, a failed start stays visible, no EffectScheduler for session start):

1. **Show the composer at key time.** Create the Agent tab and composer in the `:starting` state when the command runs, and defer only the session start behind the catalog load. Today `CatalogStartup` defers the tab as well; that is the 2.7 s before any composer appears.
2. **Send the start request without waiting.** The Editor installs the session when the reply arrives.
3. **Subscribe Ingest in `Session.init/1`** through a subscriber option, before `:start_provider` is enqueued (the Gate A shape). Without it, Ingest and the Editor still wait behind provider start and every SessionStart hook: 70 to 95 ms with no hooks and about 650 ms with a 0.5 s hook. Add one provider-ready broadcast so the `:starting` state ends on an event.
4. **Take the catalog work out of synchronous session start.** `session_model_resolve` rebuilds the catalog index on every start (62 to 68 ms), and `AgentConfig.resolve/0` walks the catalog on every hook dispatch only to read the hooks (31 to 32 ms). A cached index and a hook-only accessor remove both. SessionManager runs `init/1` synchronously, so this time would otherwise block every other SessionManager caller.
5. **Leave the Editor-process read to #3641** (`ensure_configured_model`, 49 to 60 ms).

What happens to keys typed while the tab opens: the composer is visible in the first frame after the key, so keys typed after it go to the composer the user is looking at. Keys typed before the open are handled at the file, as they are now. The draft is kept while the session starts. Send stays blocked, with the starting status visible, until the provider-ready broadcast arrives; `Session.handle_prompt` stays the authority for admission.

Expected result: the Editor work per open drops to the tab switch and one render, close to today's `SPC a a` reopen of an existing session (28 ms p50 and 40 ms p95 to the written frame). Send readiness on the first open still waits for the catalog load, about 2.7 s on this machine. The receipt shows a first open 10 s after launch is just as slow, which is the condition Gate C named for reconsidering a catalog load at launch once Gate B ships.

Not covered by this decision: the app takes 60 to 150 ms to present the first Agent frame and 74 ms to present the return to the editor. Meeting a 50 ms presented target needs a separate frontend investigation of the view switch.

## Telemetry kept

The new spans are production telemetry, kept by decision: `catalog_load`, `tab_switch`, `ensure_configured_model`, `session_subscribe`, `provider_project_view_refresh`, `session_snapshot_read`, `session_model_resolve`, `provider_start`, `session_start_hooks`, and `session_start_hook_config`, all under `[:minga, :agent, ...]`. `Minga.Telemetry.DevHandler` now logs these and the existing Agent session-start spans as `[agent:<span>] <µs>` lines at the `:agent` debug level. No temporary probes were added to the app; the trace collector exists only in the measurement config.
