# Preparing and verifying Minga builds

Prepare installable builds before deciding whether to release them. Candidate preparation uploads the complete build set to GitHub Actions, records its provenance and final-byte checksums, and gives it an immutable handle. A separate workflow downloads and verifies those exact bytes without rebuilding them.

Stable preparation and independent verification only upload GitHub Actions artifacts. They do not create tags, publish GitHub Releases, update the Homebrew tap, or edit the changelog.

## Rolling Homebrew publication

Each push to protected `main` prepares the Apple Silicon macOS TUI archive and signed, notarized GUI DMG. The workflow builds the pushed commit, assigns version `0.1.0-dev.N` (where `N` is the workflow run number), and uploads an immutable candidate handle and a separate `homebrew-recipes` artifact. A rerun has a distinct attempt but retains the same version. It must never replace an already published set of bytes.

When a new `main` push reaches the build stage, it can cancel the previous push's queued or running job for the same package. This keeps superseded builds from using macOS runners. Manual candidates and reruns do not compete with new pushes, and a newer push does not interrupt a publication already in progress.

`minga --version` reports `0.1.0-dev.N`. Homebrew recipes use `0.1.0betaN` so Homebrew orders successive builds correctly and upgrades to the first `0.1.0` stable release. The formula installs `minga`; the cask installs `Minga.app` without adding a second shell command. Recipes point to versioned release filenames, such as `minga_0.1.0-dev.123_macos_aarch64.tar.gz` and `Minga_0.1.0-dev.123.dmg`. Candidate files keep the unversioned names in their manifest; rename only the files that an approved publisher uploads, not the tested contents.

To rehearse an upgrade without publishing, independently verify two completed candidates using the exact run/attempt and manifest handles. On a clean Mac with Homebrew 7 or newer and `jq`, put each candidate's verified payloads (under their manifest names), generated recipes and the independent verifier's `receipt.json` (named `verification-receipt.json`) in a separate directory.

```bash
scripts/qualify-homebrew-upgrade /path/to/previous /path/to/next
```

On Apple Silicon, the script verifies both payloads against the independent receipts, regenerates the recipes to confirm they match, and rehearses the formula and cask upgrades through a disposable local tap and isolated download cache. It checks the installed runtime version and cask signature without bypassing Gatekeeper. Record native GUI launch and interaction separately. Before the first stable cut, rehearse from the last rolling build to the first stable candidate, generating Apple Silicon-only stable recipes with `--arm64`, `--dmg`, and `--output`.

After the macOS artifacts pass the release checks and byte verification, a protected `main` push publishes a versioned GitHub prerelease without making it the latest stable release. The publisher uses the built-in GitHub token to publish and the existing `HOMEBREW_TAP_TOKEN` to advance the formula and cask together. The tap token needs Contents write access to `jsmestad/homebrew-minga`. GitHub can reject tagging an older commit if workflow files have changed since that commit. If that happens, publish a newer qualified build or configure an optional `HOMEBREW_RELEASE_TOKEN` with Contents and Workflows write access scoped to `jsmestad/minga`. No Cloudflare account is needed.

If a build or upload fails, the tap keeps its current version. If publication succeeds but the tap push fails, rerun only the failed publishing job so it reuses the original verified artifacts. Do not rerun the build to replace released bytes. A stale run cannot replace a newer formula and cask. Check the public release and `brew upgrade` on Apple Silicon to confirm delivery; package boot checks are not native upgrade evidence.

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

`.tool-versions` is the source pin: Elixir `1.20.5-otp-29`, OTP `29.1.2`, Go `1.26.11` and native Zig `0.16.0`. Preparation selects Go explicitly; the `go/tui/go.mod` directive sets the minimum Go version for the terminal renderer. macOS jobs select Xcode 26.3 explicitly and verify the actual native host.

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

Assembly generates shared protocol sources first, then runs the BEAM and native release build alongside the Xcode Release build. It reports elapsed time for protocol generation, both builds and final bundle assembly. Xcode uses worktree-local DerivedData at `macos/.build/app-assembly` and checks the generated project's Release optimization settings before compiling. `--no-build` reuses an existing BEAM release and an existing Xcode product without regenerating or compiling either one. It looks for the ordinary Xcode product first, then for the isolated assembly product.

A failed rerun clears an old handoff file and exits without reporting a successful app. Signing failures are errors, not warnings. GUI preparation finishes Developer ID signing, notarization and stapling before hashing the final DMG.

### Signing credentials

Only the controlled GUI signing/notarization steps receive the existing Apple secrets:

- `APPLE_CERTIFICATE_P12` and `APPLE_CERTIFICATE_PASSWORD`: Developer ID Application certificate and password.
- `APPLE_ID`, `APPLE_APP_PASSWORD` and `APPLE_TEAM_ID`: notarization account, app-specific password and team.

A configured secret name does not prove the credential works. The actual build must complete the signing and notarization checks. Temporary signing material is removed after the job. Build and verification jobs have only Contents and Actions read access and never receive the Homebrew token.

## Keep the candidate identity

A candidate handle is the manifest Actions artifact ID plus the SHA256 of `manifest.json`, not the ZIP checksum. The manifest does not contain its own final artifact ID or hash.

The versioned manifest binds the repository, full source SHA, source/app version, producing workflow path/revision, run ID and attempt. It records names, targets, sizes, SHA256 values, immutable artifact IDs and ZIP digests for the two rolling Apple Silicon payloads or all five stable preparation payloads, plus toolchains and validation evidence. `SHA256SUMS.txt` covers exactly that inventory.

Payload archives contain only the named payload and its build-facts JSON. Checksums and the manifest have separate immutable archives. The verifier hashes the actual downloaded ZIP bytes and each final payload. It checks the entire archive inventory without extracting or executing downloaded files.

Artifacts and successful preparation/verification receipts have 14-day retention. A rerun creates a new generation even at the same source SHA. Rerunning only failed jobs cannot combine old successful artifacts with the new attempt. Missing, deleted, expired, duplicate, unexpected, mixed-attempt or changed artifacts make the candidate unavailable. Preparation never silently rebuilds or substitutes another generation.

A failed build can retain sanitized `diagnostic-only-*` artifacts. They are not a complete or promotable candidate. No credentials, user profile/configuration, signing private keys or provider data belong in any upload.

## Verify the exact uploaded bytes

Use the values recorded for the successful preparation, not values inferred from the manifest itself. Set `MANIFEST_ID`, `MANIFEST_SHA`, `SOURCE_SHA`, `VERSION`, `WORKFLOW_SHA`, `PREPARATION_RUN` and `PREPARATION_ATTEMPT` to that recorded candidate, then start the independent rehearsal:

```bash
gh workflow run verify-release-candidate.yml --repo jsmestad/minga --ref main -f manifest_artifact_id="$MANIFEST_ID" -f manifest_sha256="$MANIFEST_SHA" -f source_sha="$SOURCE_SHA" -f version="$VERSION" -f workflow_sha="$WORKFLOW_SHA" -f run_id="$PREPARATION_RUN" -f run_attempt="$PREPARATION_ATTEMPT"
```

The rehearsal uses trusted protected-main verifier code and read-only API access. It checks the producing workflow/run/attempt through GitHub, reads the toolchain pins from the verified source revision, downloads by immutable artifact ID, and validates the expected context, raw ZIP digests, safe inventory, final-byte hashes and checksum file. It does not build, sign, repackage or execute the candidate. A successful run retains a `candidate-verification-<run>-<attempt>` receipt containing the exact handle, context, payload hashes and checks performed.

For a local download, take `PAYLOAD_ID`, `PAYLOAD_NAME`, `ZIP_DIGEST` and `PAYLOAD_SHA` from that verified manifest. Work in a fresh directory and verify the received archive before unpacking:

```bash
gh api "repos/jsmestad/minga/actions/artifacts/$PAYLOAD_ID/zip" > candidate-payload.zip
printf '%s  candidate-payload.zip\n' "${ZIP_DIGEST#sha256:}" | shasum -a 256 -c -
mkdir candidate-payload
unzip -j candidate-payload.zip "$PAYLOAD_NAME" "$PAYLOAD_NAME.build.json" -d candidate-payload
printf '%s  candidate-payload/%s\n' "$PAYLOAD_SHA" "$PAYLOAD_NAME" | shasum -a 256 -c -
```

The local-only `scripts/release_candidate.py` also supports the workflow's `checksums`, `create` and `verify` operations. Pass the `.tool-versions` file from the independently verified source revision via `--source-tool-versions`, along with independently acquired context/API metadata and the original raw `<artifactID>.zip` downloads. Re-zipping extracted files does not reproduce the transport identity.

## Separate package checks from release qualification

`scripts/check-release-contents` checks concrete resource presence, release/app metadata, native headers and package containment. Standalone preparation also supplies `--runtime-receipt` to inspect actual ERTS and NIF library dependencies, ELF interpreter binding or Mach-O minimum OS, and reject unbundled or build-root dependencies. The workflow additionally boots final standalone bytes or the final mounted signed DMG's terminal launcher, checks packaged ERTS, verifies a fixed-result OTP crypto hash and opens/closes the SQLite NIF. These checks identify what ran; they do not claim native GUI interaction, an installed authored-source workflow, sustained use or release approval.

Package smoke commands run with a private home, XDG directories, and temporary directory so they do not use the runner's Minga profile. The signed DMG smoke probes a private IPC directory when the packaged helper supports it. For older packages, the workflow checks nonce generation and argument rejection without probing the installed endpoint.

Before promoting a stable candidate, qualify the exact unchanged candidate from clean user state without a development checkout or build caches. Retain the full runtime/recovery, Swift GUI and Go TUI interaction, programmability/X0 and installed-distribution evidence required by [the v0.1.0 plan](https://github.com/jsmestad/minga/issues/3542). Verify the actual minimum supported OS and every architecture-specific package. Development-build evidence is not installed-package evidence.

Stable release approval must name the exact source, candidate handle, run/attempt, asset hashes and immutable qualification evidence. Expired assets require a new prepared generation and new qualification/approval, not an implicit rebuild. Stable preparation does not publish. Tags do not start a replacement build or publication path.

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

## SDK

`minga_sdk` is the compile-time package extension authors depend on. It is versioned and published separately from Minga, from the `sdk/` directory, and only a maintainer publishes it from their own Hex account. Publish a new SDK version before any extension that depends on it, so that extension can resolve its dependency.

1. Start from a green `main`. The `Test (Extension SDK)` CI job must pass for the commit you release, including its docs and package build.
2. Bump `@version` in `sdk/mix.exs` and add the matching entry to `sdk/CHANGELOG.md`. If the release needs a newer Minga, update the compatibility table in both `sdk/CHANGELOG.md` and `sdk/README.md`. Merge that change through a pull request.
3. Build the package and review exactly what will ship:

   ```bash
   cd sdk
   mix deps.get
   mix hex.build
   ```

   The file list must contain only `lib/`, `mix.exs`, `README.md`, `CHANGELOG.md`, and `LICENSE`. Stop if anything else appears.
4. Publish from your own account with `mix hex.publish`. HexDocs source links point at `main`. Hex shows the package and docs before asking for confirmation; check the version and file list again there.
5. Publish or update dependent extensions only after the new SDK version is visible on Hex.

## Marketing site and staging previews (Cloudflare Pages)

The combined marketing site (`site/`) and ExDoc documentation (`/docs/`) assemble into `_site/` via `scripts/build_site.sh` and are validated by `python3 scripts/check_site_links.py _site --expect-noindex`. `.github/workflows/site.yml` runs this build and link check on every pull request touching site, docs, assets, or ExDoc configuration, and deploys to Cloudflare Pages when repository secrets are available. Forked pull requests skip deployment cleanly while still running the full build and link checks.

### One-time Cloudflare Pages setup

1. Create a Cloudflare Pages project named `mingacode-site` (Direct Upload mode, or set repository variable `CLOUDFLARE_PAGES_PROJECT` to override the project name).
2. Create a Cloudflare API token scoped to `Account -> Cloudflare Pages -> Edit`.
3. Add `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` as GitHub Actions repository secrets on `jsmestad/minga`.

Until v0.1.0 launches, Cloudflare Pages deployments stay on `*.pages.dev` with crawler opt-out enforced in `site/_headers` (`X-Robots-Tag: noindex, nofollow`), `site/robots.txt` (`Disallow: /`), and `<meta name="robots" content="noindex, nofollow">` in site HTML. The existing GitHub Pages job in `.github/workflows/ci.yml` keeps serving `https://jsmestad.github.io/minga/` without interruption during pre-release.

### v0.1.0 launch cutover checklist (`mingacode.dev`)

Perform this cutover only after explicit v0.1.0 release approval and publication:

1. Attach `mingacode.dev` as the primary custom domain on the Cloudflare Pages project, configure `mingacode.com` to 301-redirect to `https://mingacode.dev/` (preserving path), and verify TLS issuance on both domains.
2. Remove `X-Robots-Tag: noindex, nofollow` from `site/_headers`, remove `<meta name="robots" content="noindex, nofollow">` from `site/` HTML pages, update `site/robots.txt` to allow crawling, and drop `--expect-noindex` from `.github/workflows/site.yml`.
3. Verify `https://mingacode.dev/`, `https://mingacode.dev/docs/`, and legacy redirects (`/getting-started.html` -> `/docs/getting-started.html`) return expected status codes and assets.
4. Replace the legacy GitHub Pages artifact in `.github/workflows/ci.yml` with a redirect stub pointing `https://jsmestad.github.io/minga/` to `https://mingacode.dev/docs/`.
