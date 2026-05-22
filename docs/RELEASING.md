# Releasing Minga

This document covers how to cut a release and what infrastructure supports it.

## Prerequisites

### GitHub Secrets

The release workflow requires these secrets in the repo's Settings > Secrets and variables > Actions:

- **`HOMEBREW_TAP_TOKEN`**: A GitHub Personal Access Token (classic) with `repo` scope, scoped to the `jsmestad/homebrew-minga` repository. The release workflow uses this to push formula and cask updates to the Homebrew tap after a stable release is published.
- **`APPLE_CERTIFICATE_P12`**: Base64-encoded Developer ID Application certificate used to sign `Minga.app`.
- **`APPLE_CERTIFICATE_PASSWORD`**: Password for the Developer ID certificate.
- **`APPLE_ID`**: Apple ID used for notarization.
- **`APPLE_APP_PASSWORD`**: App-specific password for the Apple ID.
- **`APPLE_TEAM_ID`**: Apple Developer Team ID used for notarization.

The built-in `GITHUB_TOKEN` handles creating the GitHub Release and updating `CHANGELOG.md`.

## Cutting a Release

1. **Bump the version** in `mix.exs` (`@version "x.y.z"`).
2. **Commit and push** the version bump to `main` via a PR.
3. **Tag and push** the release:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```
4. The release workflow validates the tag targets the version in `mix.exs`, runs CI, builds binaries for all four platforms, smoke-tests each one, creates a GitHub Release with checksums, updates the Homebrew tap, and prepends the changelog.

### Pre-releases

Tags with a hyphen (e.g., `v0.1.0-alpha.1` or `v0.1.0-rc.1`) are treated as pre-releases:
- The tag's base version must match `mix.exs`. For example, `mix.exs` can stay at `0.1.0` while you cut `v0.1.0-alpha.1` and `v0.1.0-rc.1`.
- The GitHub Release is marked as a pre-release.
- The Homebrew tap is **not** updated (only stable releases update the formula and cask).

### What Gets Built

| Target | Runner | Binary Name |
|--------|--------|-------------|
| macOS ARM | `macos-14` | `minga_macos_aarch64` |
| macOS Intel | `macos-13` | `minga_macos_x86_64` |
| Linux x86_64 | `ubuntu-latest` | `minga_linux_x86_64` |
| Linux ARM | `ubuntu-24.04-arm` | `minga_linux_aarch64` |

### Homebrew Cask (macOS GUI)

The release workflow also generates the `minga-mac` Homebrew cask for the macOS GUI app, but only if a `Minga.dmg` artifact exists in the release. Until the GUI ships `.dmg` builds, the cask step is skipped automatically.

## Verifying a Release

After the workflow completes:

```bash
# Download and run the binary for your platform
gh release download v0.1.0 --pattern "minga_macos_aarch64"
chmod +x minga_macos_aarch64
./minga_macos_aarch64 --version

# Or install via Homebrew (stable releases only)
brew install jsmestad/minga/minga
minga --version

# Install the macOS app cask
brew install --cask jsmestad/minga/minga-mac
```

## Burrito

Minga uses [Burrito](https://github.com/burrito-elixir/burrito) to package the Elixir release as a self-extracting binary. Burrito currently requires Zig 0.15.2 for the wrap step, while Minga's Zig renderer uses the project Zig version from `.tool-versions`. The release workflow compiles the project with `ZIG_VERSION`, switches to `BURRITO_ZIG_VERSION`, then runs `mix release minga --no-compile` so Burrito can wrap the already-compiled release. When upgrading Burrito, check `Burrito.get_versions/0`, update `BURRITO_ZIG_VERSION` if needed, and run `mix deps.get` to update `mix.lock`.
