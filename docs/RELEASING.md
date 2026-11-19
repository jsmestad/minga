# Preparing and verifying Minga builds

Prepare installable builds before deciding whether to release them. Candidate preparation uploads the complete build set to GitHub Actions, records its provenance and final-byte checksums, and gives it an immutable handle. A separate workflow downloads and verifies those exact bytes without rebuilding them.

These are ordinary public build artifacts. They are not GitHub Releases. Neither workflow creates a tag, publishes a release, updates the Homebrew tap or edits the changelog. Version and release-note changes go through reviewed pull requests.

## Prepare and test rolling Homebrew builds

Each push to protected `main` prepares the two macOS TUI archives and the signed, notarized Apple Silicon DMG. The workflow builds the pushed commit, assigns the version `0.1.0-dev.N` (where `N` is the workflow run number) and uploads an immutable candidate handle and a separate `homebrew-recipes` artifact. A rerun has a distinct attempt but retains the same version. It must never replace an already published set of bytes.

`minga --version` reports `0.1.0-dev.N`. Homebrew recipes use `0.1.0betaN` so Homebrew orders successive builds correctly and upgrades to the first `0.1.0` stable release. The formula installs `minga`; the cask installs `Minga.app` without adding a second shell command. Recipes point to versioned release filenames, such as `minga_0.1.0-dev.123_macos_aarch64.tar.gz` and `Minga_0.1.0-dev.123.dmg`. Candidate files keep the unversioned names in their manifest; rename only the files that an approved publisher uploads, not the tested contents.

To rehearse an upgrade without publishing, independently verify two completed candidates using the exact run/attempt and manifest handles. On a clean Mac with Homebrew 7 or newer and `jq`, put each candidate's verified payloads (under their manifest names), generated recipes and the independent verifier's `receipt.json` (named `verification-receipt.json`) in a separate directory.

```bash
scripts/qualify-homebrew-upgrade /path/to/previous /path/to/next
```

The script checks the payloads against the independent receipts and regenerates recipes to confirm they match before installing. It copies the unchanged recipes into a disposable local tap and seeds an isolated Homebrew download cache at the paths for their release URLs. Run it on both macOS architectures for the formula and on Apple Silicon for the cask. It checks the installed runtime version and cask signature without bypassing Gatekeeper. Record native GUI launch and interaction evidence separately. Before the first stable cut, also run the rehearsal with the last rolling build and the first stable candidate, generating stable recipes with `--dmg` and `--output`.

Nothing here creates GitHub Release tags, uploads public release assets or mutates the real tap. Those actions still require separate authorization.

## Prepare a stable candidate

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
| `minga_macos_aarch64.tar.gz` | Apple Silicon macOS TUI | `macos-15` |
| `minga_macos_x86_64.tar.gz` | Intel macOS TUI | `macos-15-intel` |
| `minga_linux_x86_64.tar.gz` | Linux x86_64 TUI, Ubuntu 24.04 glibc baseline | `ubuntu-24.04` |
| `minga_linux_aarch64.tar.gz` | Linux ARM64 TUI, Ubuntu 24.04 glibc baseline | `ubuntu-24.04-arm` |

Runner labels are configuration, not architecture evidence. Each job checks its actual host, ERTS, Go renderer, parser, hook runner and packaged native libraries. There is no Intel GUI, Linux GUI or Windows artifact in this matrix. A missing target or DMG fails preparation rather than producing a smaller candidate.

### Toolchains and app construction

`.tool-versions` is the source pin: Elixir `1.20.5-otp-29`, OTP `29.1.2`, Go `1.26.4` and native Zig `0.16.0`. Preparation selects Go explicitly; the `go/tui/go.mod` language directive is not a compiler-version pin. macOS jobs select Xcode 26.3 explicitly and verify the actual native host.

The TUI ships as a native Mix release tarball. The GUI still embeds the plain `minga_macos` release in `Minga.dmg`.

Standalone preparation builds OTP and OpenSSL from checksum-pinned sources in `scripts/release_erts_sources.json`. macOS uses Xcode 26.3 build 17C529 with a minimum deployment target of macOS 15.0. Linux uses the Ubuntu 24.04 host's glibc and loader. Alpine and older glibc versions are not qualified by this build.

The producer writes `erts.tar.gz` and a successful `receipt.json` only after source integrity, native architecture, runtime/header completeness, library closure, crypto execution and platform ABI checks pass. A failed rerun invalidates the old successful receipt. For a native standalone build, create the input before invoking Mix:

```bash
python3 scripts/build-release-erts.py --os macos --arch aarch64 --output "$PWD/erts-input"
MINGA_RELEASE_ERTS_RECEIPT="$PWD/erts-input/receipt.json" MIX_ENV=prod make release-tui
```

Use the matching native target on other hosts. `mix release.tui` checks the receipt and provides the verified runtime to Mix during assembly. It rejects an absent or mismatched receipt rather than substituting the host's ERTS.

The input receipt is not final package qualification. The final archive must still unpack in fresh state, boot the selected runtime, and execute crypto and SQLite checks on its native target.

Failed commands report a bounded tail of their actual output, not only an ephemeral runner path. Failure artifacts retain only the isolated public-source command logs alongside existing sanitized context/toolchain facts. They do not upload the build home, source tree, credentials or signing material. These diagnostic artifacts are never candidate evidence.

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

The versioned manifest binds the repository, full source SHA, source/app version, producing workflow path/revision, run ID and attempt. It records the names, targets, sizes, SHA256 values, immutable artifact IDs and ZIP transport digests for all three rolling macOS payloads or all five stable payloads, plus actual toolchains and declared validation evidence. `SHA256SUMS.txt` covers exactly that inventory.

Payload archives contain only the named payload and its build-facts JSON. Checksums and the manifest have separate immutable archives. The verifier hashes the actual downloaded ZIP bytes and each final payload. It checks the entire archive inventory without extracting or executing downloaded files.

Artifacts and successful preparation/verification receipts have 14-day retention. A rerun creates a new generation even at the same source SHA. Rerunning only failed jobs cannot combine old successful artifacts with the new attempt. Missing, deleted, expired, duplicate, unexpected, mixed-attempt or changed artifacts make the candidate unavailable. Preparation never silently rebuilds or substitutes another generation.

A failed build can retain sanitized `diagnostic-only-*` artifacts. They are not a complete or promotable candidate. No credentials, user profile/configuration, signing private keys or provider data belong in any upload.

## Verify the exact uploaded bytes

Use the values recorded for the successful preparation, not values inferred from the manifest itself. Set `MANIFEST_ID`, `MANIFEST_SHA`, `SOURCE_SHA`, `VERSION`, `WORKFLOW_SHA`, `PREPARATION_RUN` and `PREPARATION_ATTEMPT` to that recorded candidate, then start the independent rehearsal:

```bash
gh workflow run verify-release-candidate.yml --repo jsmestad/minga --ref main -f manifest_artifact_id="$MANIFEST_ID" -f manifest_sha256="$MANIFEST_SHA" -f source_sha="$SOURCE_SHA" -f version="$VERSION" -f workflow_sha="$WORKFLOW_SHA" -f run_id="$PREPARATION_RUN" -f run_attempt="$PREPARATION_ATTEMPT"
```

The rehearsal uses trusted protected-main verifier code and read-only API access. It checks the producing workflow/run/attempt through GitHub, downloads by immutable artifact ID, and validates the expected context, raw ZIP digests, safe inventory, final-byte hashes and checksum file. It does not build, sign, repackage or execute the candidate. A successful run retains a `candidate-verification-<run>-<attempt>` receipt containing the exact handle, context, payload hashes and checks performed.

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

`scripts/check-release-contents` checks concrete resource presence, release/app metadata, native headers and package containment. Standalone preparation also supplies `--runtime-receipt` to inspect actual ERTS and NIF library dependencies, ELF interpreter binding or Mach-O minimum OS, and reject unbundled or build-root dependencies. The workflow additionally boots final standalone bytes or the final mounted signed DMG's terminal launcher, checks packaged ERTS, verifies a fixed-result OTP crypto hash and opens/closes the SQLite NIF. These checks identify what ran; they do not claim native GUI interaction, an installed authored-source workflow, sustained use or release approval.

Before any later promotion, qualify the exact unchanged candidate from clean user state without a development checkout or build caches. Retain the full runtime/recovery, Swift GUI and Go TUI interaction, programmability/X0 and installed-distribution evidence required by [the v0.1.0 plan](https://github.com/jsmestad/minga/issues/3542). Verify the actual minimum supported OS and every architecture-specific package. Development-build evidence is not installed-package evidence.

Any later release approval must name the exact source, candidate handle, run/attempt, asset hashes and immutable qualification evidence. Expired assets require a new prepared generation and new qualification/approval, not an implicit rebuild. This preparation path contains no publication-capable job; Homebrew channel selection and any external publication need separate explicit authorization. Tags do not start a replacement build/publication path.

## Prepare package-manager installs

Use the verified standalone tarballs as inputs, not a separately rebuilt release. Ubuntu packages install `minga` on `PATH` and keep the bundled runtime together under `/usr/lib/minga`. On macOS, the Homebrew formula installs the same runtime under Homebrew's private package directory and links `minga` into Homebrew's `bin`.

From the source checkout, use the release workflow's pinned Python and set `assets` to the directory containing the verified tarballs. Install `dpkg-deb` (provided by `dpkg` on Ubuntu) to build the Debian packages. Use the candidate's version in each command:

```bash
assets=/absolute/path/to/verified/assets
scripts/build-tui-deb "$assets/minga_linux_x86_64.tar.gz" --version 0.1.0 --arch amd64 --output "$assets"
scripts/build-tui-deb "$assets/minga_linux_aarch64.tar.gz" --version 0.1.0 --arch arm64 --output "$assets"
scripts/render-tui-formula --version 0.1.0 --arm64 "$assets/minga_macos_aarch64.tar.gz" --x86-64 "$assets/minga_macos_x86_64.tar.gz" > "$assets/minga.rb"
```

Install a local Ubuntu package with `sudo apt install "$assets/minga_0.1.0_amd64.deb"`. After publication, macOS users can install from the tap with `brew install jsmestad/minga/minga`.

Before release approval, install and remove the `.deb` on clean Ubuntu 24.04 hosts of both supported architectures and run `minga --version` from `PATH`. Test the generated formula on both macOS architectures against the exact assets it names. Do not update the tap until those assets are available and their SHA-256 hashes match the formula.

For Arch Linux and Omarchy on x86-64, build a local pacman package on an Arch host with `base-devel` installed. In an empty build directory, place `packaging/arch/PKGBUILD`, the checkout's `LICENSE`, and the verified `minga_linux_x86_64.tar.gz` and `SHA256SUMS.txt`. Set `pkgver` to the candidate version. Then run:

```bash
makepkg --cleanbuild
sudo pacman -U ./minga-0.1.0-1-x86_64.pkg.tar.zst
minga --version
```

Use `sudo pacman -R minga` to remove it. Qualify the installed package on Arch or Omarchy before offering it for download. This recipe does not publish to the AUR.

## Running the standalone TUI

Extract an archive into an empty directory and run its launcher. Keep the release directory intact when adding the launcher to `PATH`.

```bash
tar -xzf minga_macos_aarch64.tar.gz
./minga/launchers/minga --version
```

Use the archive that matches your OS and CPU. The launcher maps `--cookie-file`, `MINGA_COOKIE` and `RELEASE_COOKIE` in that order. It clears inherited VM flags, supplies a random fallback cookie, and starts the VM with distribution off.
