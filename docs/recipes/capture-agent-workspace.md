# Capture the native agent workspace

Use fixture stills to inspect layout, and a real native session to prove input and state ownership. Neither replaces the other. A readable PreviewHost image cannot prove that keyboard or mouse input reached the BEAM, and a headless session cannot prove what the native window displayed.

Both channels gate acceptance of macOS agent-workspace UI work, not the start of focused repairs. The [Go renderer capture track](https://github.com/jsmestad/minga/issues/3445) proves terminal output separately; it does not replace either native channel.

## Repeatable production-view stills

From a development checkout with the pinned editor tools and normal macOS build prerequisites installed, run:

```bash
capture_dir=$(mktemp -d "${TMPDIR:-/tmp}/minga-agent-stills.XXXXXX")
PREVIEW_OUTPUT_DIR="$capture_dir" scripts/preview.sh --agent-workspace --wall-timeout 600
```

This uses the existing PreviewHost, production `ContentView` and editor renderer with an immutable completed transcript. It freezes motion and captures one supported theme, Doom One, at both widths:

| Width in points | PNG |
|---:|---|
| 800 | `AgentChromeView-800-doom-one.png` |
| 1200 | `AgentChromeView-1200-doom-one.png` |

The deadline includes protocol generation, project generation, compilation and capture. An unavailable renderer, failed command, unstable image or expired deadline is a failure, not a successful screenshot of an error panel. The command removes stale images for the selected captures before starting.

Agent fixtures wait up to five seconds for the canonical prompt to reach the production Metal surface.
A readiness timeout reports placement, presentation and native host state instead of capturing an unready frame.

Keep `preview-run.json`, each PNG and its adjacent JSON together. They record actual source and executable hashes, generated protocol inputs, build command, OS, Xcode, Swift, SDK, fonts, backing scale and window/image dimensions. Git revision alone does not identify uncommitted source changes. The source hashes bind those changes to the build.

Inspect the full shell, transcript, tool cards, composer and footer. Do not accept a blank strip or clipped footer because the process returned zero. A short bottom-anchored transcript can leave space above it. The metadata explicitly reports when production chat hides the editor renderer; that image does not prove visible editor pixels.

For cold/warm measurements, set `PREVIEW_DERIVED_DATA` to a new private directory for the first run and reuse it for the second. Retain both receipts and report the actual build configuration and toolchain. Do not present Debug captures as installed-release qualification.

## Compare the base without replacing its production views

The existing `scripts/chrome_preview_evidence.py prepare-base` command installs the same preview-only fixtures and capture transport in a separate base checkout. Its manifest records original and installed hashes. It does not copy proposed production Views sources into the base.

The agent-workspace comparison uses the repaired complete Doom One palette and frozen fixture on both sides. It does not compare against the old unreadable neutral-gray fixture. Keep that limit with the images; equal pixels under a shared fixture do not prove live-session behavior. Use the existing before/after pipeline rather than creating a second screenshot framework.

## Real keyboard and mouse proof

Use the actual native frontend and BEAM, not PreviewHost, EditorCase, a mock provider or an installed app from another revision. Build normal runtime support and the native frontend first:

```bash
mix native.build.support
mix swift.build
```

For a source-session inspection console, launch the same application from IEx:

```bash
iex -S mix run --no-start -e 'Minga.SafeMode.put(true); Application.put_env(:minga, :start_editor, true); Application.put_env(:minga, :backend, :gui); Mix.Task.run("app.start"); Minga.CLI.main(["--safe"])'
```

Safe mode avoids user extensions. Use the approved credential owner and normal supported authentication flow. Do not copy credentials or user configuration into an evidence directory. Missing authentication, a missing parser, a blank window or an early startup sample is not qualified live proof.

Wait for the native window, then create two distinct fresh agent sessions through the native UI. Type a unique visible marker and a normal question into each session using the actual native composer. Keep both transcripts distinguishable. Do not load a saved session into the same process for this A/B identity proof.

Define this read-only observation in IEx after a real session is active:

```elixir
observe = fn ->
  started = DateTime.utc_now()
  state = :sys.get_state(MingaEditor)
  session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)
  true = is_pid(session)
  session_id = MingaAgent.Session.session_id(session)
  {:ok, ^session_id} = MingaAgent.SessionManager.session_id_for_pid(session)
  correlation = state.render.render_correlation
  acknowledged = MingaEditor.Renderer.Server.acknowledgement_state(state.render.renderer)

  %{
    observed_from: started,
    observed_to: DateTime.utc_now(),
    session_id: session_id,
    process_ids: {Process.whereis(MingaEditor), session, state.render.renderer},
    latest_intent: MingaEditor.State.RenderCorrelation.latest_intent_revision(correlation),
    render_receipt: {
      MingaEditor.State.RenderCorrelation.last_receipt_revision(correlation),
      MingaEditor.State.RenderCorrelation.last_receipt_sequence(correlation)
    },
    frontend_acknowledged: acknowledged,
    render_scheduled?: MingaEditor.State.RenderCorrelation.scheduled?(correlation)
  }
end

evidence = Path.join(System.tmp_dir!(), "minga-live-#{System.system_time(:microsecond)}")
File.mkdir_p!(evidence)
File.chmod!(evidence, 0o700)
File.write!(Path.join(evidence, "a-before.term"), inspect(observe.(), pretty: true))
```

Record observations before and after each physical interaction. Use a different filename for each observation. Keep the corresponding native-window image and a short ledger with the action, actual input method, visible marker, authoritative session ID and observation interval. Record the actual source/binary provenance, OS, build, font and backing scale. Do not include credentials or complete private transcripts.

A session PID is not a business identity. A tab title or opaque transcript epoch is not a session ID. Check the visible transcript marker against the recorded authoritative ID, not only the currently active PID. The observations above are separate queries, not an atomic snapshot.

The render receipt and frontend acknowledgement bound transport progress. They do not attest to compositor presentation, and a Metal editor observation does not prove that the SwiftUI agent transcript was visible. Human inspection of the actual window is required. If the IDs, process episode, bounds or visible marker disagree, record a failed attempt instead of assigning the image to a guessed session.

Cover each case independently:

| Case | Required observation |
|---|---|
| Keyboard | Native typing/submission changes the real session and its visible transcript. |
| Mouse | Selecting the other real session through its native session UI changes the BEAM identity and visible marker. |
| Session switch during capture | The result has the correct visible marker and observation bounds, or an explicit temporal failure. |
| Streaming during capture | The visible partial transcript is correctly identified, or the unsettled attempt fails explicitly. |
| Disconnect | No stale image or unavailable query becomes a successful evidence row. |
| Restart and reconnect | Record the new process/generation episode and restored real identity, or the explicit failure. |

Do not infer success from a launch, a protocol acknowledgement, a fixture or an unexecuted procedure. If input or Accessibility control is unavailable, have a human execute this procedure. Do not change permissions or substitute an automation bypass. Keep live acceptance open until the actual keyboard, mouse and temporal attempts are recorded.

For terminal-only screen baselines, use [Update screen snapshots](update-snapshots.md). The ownership boundary behind these checks is documented in [Architecture](../ARCHITECTURE.md).
