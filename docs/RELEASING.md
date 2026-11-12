# Preparing and verifying Minga builds

Prepare installable builds before deciding whether to release them. Candidate preparation uploads the complete build set to GitHub Actions, records its provenance and final-byte checksums, and gives it an immutable handle. A separate workflow downloads and verifies those exact bytes without rebuilding them.

These are ordinary public build artifacts. They are not GitHub Releases. Neither workflow creates a tag, publishes a release, updates the Homebrew tap or edits the changelog. Version and release-note changes go through reviewed pull requests.

## Prepare a candidate

The preparation workflow builds a full reviewed source SHA from protected-main history. The source version must match `mix.exs`, and the GUI version must match its embedded release. The producing workflow revision is recorded separately from the selected source SHA.

For the current version, start a build from the latest protected main:

```bash
SOURCE_SHA=$(gh api repos/jsmestad/minga/commits/main --jq .sha)
gh workflow run release.yml --repo jsmestad/minga --ref main -f source_sha="$SOURCE_SHA" -f version=0.1.0
```

Open the exact run you started and retain its run ID and attempt. Do not select an artifact by a mutable name or assume the latest run is the one you approved. The successful preparation summary lists the source SHA, producing workflow revision, run/attempt, manifest artifact ID, manifest-file SHA256 and final asset checksums.

Every preparation uses this complete inventory:

| Final payload | Native target | Preparation runner |
|---|---|---|
| `Minga.dmg` | Apple Silicon macOS GUI, declared minimum macOS 15.0 | `macos-15` |
| `minga_macos_aarch64` | Apple Silicon macOS TUI | `macos-15` |
| `minga_macos_x86_64` | Intel macOS TUI | `macos-15-intel` |
| `minga_linux_x86_64` | Linux x86_64 TUI | `ubuntu-24.04` |
| `minga_linux_aarch64` | Linux ARM64 TUI | `ubuntu-24.04-arm` |

Runner labels are configuration, not architecture evidence. Each job checks its actual host, ERTS, Go renderer, parser, hook runner and packaged native libraries. There is no Intel GUI, Linux GUI or Windows artifact in this matrix. A missing target or DMG fails preparation rather than producing a smaller candidate.

### Toolchains and app construction

`.tool-versions` is the source pin: Elixir `1.20.5-otp-29`, OTP `29.1.2`, Go `1.26.4` and native Zig `0.16.0`. Preparation selects Go explicitly; the `go/tui/go.mod` language directive is not a compiler-version pin. macOS jobs select Xcode 26.3 explicitly and verify the actual native host.

The locked Burrito 1.6.0 declares wrapper Zig `0.16.0`. The workflow checks `Burrito.get_versions/0` before wrapping and records native-Zig and wrapper-Zig facts separately, even when their versions are equal. `BURRITO_TARGET` selects exactly one existing target per standalone job. The GUI embeds the plain `minga_macos` release instead of a Burrito wrapper.

macOS runtime components can be universal Mach-O images. The checker validates their architecture tables and actual slice headers, then requires the declared CPU to be present in every native component. The final package must also boot and report the expected active runtime architecture, including working OTP crypto and SQLite native operations. This qualifies the selected target, not a universally runnable whole package; the wrapper, renderer and helpers can remain target-specific.

`mix app.assemble` resolves its app through Xcode build settings. Automation consumes its successful absolute output path instead of searching cached DerivedData:

```bash
MIX_ENV=prod mix app.assemble --output-path-file /tmp/minga-app-path
```

A failed rerun clears an old handoff file and exits without reporting a successful app. Signing failures are errors, not warnings. GUI preparation finishes Developer ID signing, notarization and stapling before hashing the final DMG.

### Signing credentials

Only the controlled GUI signing/notarization steps receive the existing Apple secrets:

- `APPLE_CERTIFICATE_P12` and `APPLE_CERTIFICATE_PASSWORD`: Developer ID Application certificate and password.
- `APPLE_ID`, `APPLE_APP_PASSWORD` and `APPLE_TEAM_ID`: notarization account, app-specific password and team.

A configured secret name does not prove the credential works. The actual build must complete the signing and notarization checks. Temporary signing material is removed after the job. No Homebrew token is consumed. The workflow token has only contents/actions read permissions; artifact uploads use the Actions artifact service.

## Keep the candidate identity

A candidate handle is the manifest Actions artifact ID plus the SHA256 of `manifest.json`, not the ZIP checksum. The manifest does not contain its own final artifact ID or hash.

The versioned manifest binds the repository, full source SHA, source/app version, producing workflow path/revision, run ID and attempt. It includes all five final payload names, targets, sizes, SHA256 values, immutable artifact IDs and ZIP transport digests, plus actual toolchain and declared validation evidence. `SHA256SUMS.txt` covers exactly the five final payloads; its identity is also recorded.

Payload archives contain only the named payload and its build-facts JSON. Checksums and the manifest have separate immutable archives. The verifier hashes the actual downloaded ZIP bytes and each final payload. It checks the entire archive inventory without extracting or executing downloaded files.

Artifacts and successful preparation/verification receipts have 14-day retention. A rerun creates a new generation even at the same source SHA. Rerunning only failed jobs cannot combine old successful artifacts with the new attempt. Missing, deleted, expired, duplicate, unexpected, mixed-attempt or changed artifacts make the candidate unavailable. Preparation never silently rebuilds or substitutes another generation.

A failed build can retain sanitized `diagnostic-only-*` artifacts. They are not a complete or promotable candidate. No credentials, user profile/configuration, signing private keys or provider data belong in any upload.

## Verify the exact uploaded bytes

Use the values recorded for the successful preparation, not values inferred from the manifest itself. Set `MANIFEST_ID`, `MANIFEST_SHA`, `SOURCE_SHA`, `WORKFLOW_SHA`, `PREPARATION_RUN` and `PREPARATION_ATTEMPT` to that recorded candidate, then start the independent rehearsal:

```bash
gh workflow run verify-release-candidate.yml --repo jsmestad/minga --ref main -f manifest_artifact_id="$MANIFEST_ID" -f manifest_sha256="$MANIFEST_SHA" -f source_sha="$SOURCE_SHA" -f version=0.1.0 -f workflow_sha="$WORKFLOW_SHA" -f run_id="$PREPARATION_RUN" -f run_attempt="$PREPARATION_ATTEMPT"
```

The rehearsal uses trusted protected-main verifier code and read-only API access. It checks the producing workflow/run/attempt through GitHub, downloads by immutable artifact ID, and validates the expected context, raw ZIP digests, safe inventory, final-byte hashes and checksum file. It does not build, sign, repackage or execute the candidate. A successful run retains a `candidate-verification-<run>-<attempt>` receipt containing the exact handle, context, five hashes and checks performed.

For a local download, take `PAYLOAD_ID`, `PAYLOAD_NAME`, `ZIP_DIGEST` and `PAYLOAD_SHA` from that verified manifest. Work in a fresh directory and verify the received archive before unpacking:

```bash
gh api "repos/jsmestad/minga/actions/artifacts/$PAYLOAD_ID/zip" > candidate-payload.zip
printf '%s  candidate-payload.zip\n' "${ZIP_DIGEST#sha256:}" | shasum -a 256 -c -
mkdir candidate-payload
unzip -j candidate-payload.zip "$PAYLOAD_NAME" "$PAYLOAD_NAME.build.json" -d candidate-payload
printf '%s  candidate-payload/%s\n' "$PAYLOAD_SHA" "$PAYLOAD_NAME" | shasum -a 256 -c -
```

The local-only `scripts/release_candidate.py` also supports the workflow's `checksums`, `create` and `verify` operations. Those operations require independently acquired context/API metadata and the original raw `<artifactID>.zip` downloads. Re-zipping extracted files does not reproduce the transport identity.

## Separate package checks from release qualification

`scripts/check-release-contents` checks concrete resource presence, release/app metadata, native headers and package containment. The workflow additionally boots final standalone bytes or the final mounted signed DMG's terminal launcher, checks packaged ERTS, verifies a fixed-result OTP crypto hash and opens/closes the SQLite NIF. These checks identify what ran; they do not claim native GUI interaction, an installed authored-source workflow, sustained use or release approval.

Before any later promotion, qualify the exact unchanged candidate from clean user state without a development checkout or build caches. Retain the full runtime/recovery, Swift GUI and Go TUI interaction, programmability/X0 and installed-distribution evidence required by [the v0.1.0 plan](https://github.com/jsmestad/minga/issues/3542). Verify the actual minimum supported OS and every architecture-specific package. Development-build evidence is not installed-package evidence.

Any later release approval must name the exact source, candidate handle, run/attempt, asset hashes and immutable qualification evidence. Expired assets require a new prepared generation and new qualification/approval, not an implicit rebuild. This preparation path contains no publication-capable job; Homebrew channel selection and any external publication need separate explicit authorization. Tags do not start a replacement build/publication path.

## Burrito's pre-VM boundary

Minga uses [Burrito](https://github.com/burrito-elixir/burrito) for standalone self-extracting releases. Distribution cookies must exist as `RELEASE_COOKIE` before the process starts; setting only `MINGA_COOKIE` inside application code is too late because the VM already exists. Direct execution of a downloaded raw Burrito artifact requires `RELEASE_COOKIE` whenever distribution will be enabled.

Existing Homebrew and bundled GUI/TUI wrappers map `--cookie-file`, `MINGA_COOKIE` and `RELEASE_COOKIE` in that precedence order before VM startup. Non-distributed wrapper boots clear inherited `ERL_AFLAGS`, `ERL_FLAGS`, `ERL_ZFLAGS`, `ELIXIR_ERL_OPTIONS` and `RELEASE_VM_ARGS`, then install a fresh random fallback cookie. A local editor cannot accidentally inherit distribution or the baked-in release cookie.

For a direct standalone version check, supply the cookie before launching the downloaded bytes:

```bash
chmod +x candidate-payload/minga_macos_aarch64
RELEASE_COOKIE="$(openssl rand -hex 32)" RELEASE_DISTRIBUTION=none candidate-payload/minga_macos_aarch64 --version
```
