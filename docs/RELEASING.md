# Releasing Minga

This document covers how to cut a release and what infrastructure supports it.

## Prerequisites

### GitHub Secrets

The release workflow requires one secret configured in the repo's Settings > Secrets and variables > Actions:

- **`HOMEBREW_TAP_TOKEN`**: A GitHub Personal Access Token (classic) with `repo` scope, scoped to the `jsmestad/homebrew-minga` repository. The release workflow uses this to push formula updates to the Homebrew tap after a stable release is published.

The built-in `GITHUB_TOKEN` handles everything else (creating the GitHub Release, updating `CHANGELOG.md`).

## Cutting a Release

1. **Bump the version** in `mix.exs` (`@version "x.y.z"`).
2. **Commit and push** the version bump to `main` via a PR.
3. **Tag and push** the release:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```
4. The release workflow validates the tag matches `mix.exs`, runs CI, builds binaries for all four platforms, smoke-tests each one, creates a GitHub Release with checksums, updates the Homebrew tap, and prepends the changelog.

### Pre-releases

Tags with a hyphen (e.g., `v0.1.0-rc.1`) are treated as pre-releases:
- The GitHub Release is marked as a pre-release.
- The Homebrew tap is **not** updated (only stable releases update the formula).

### What Gets Built

| Target | Runner | Binary Name |
|--------|--------|-------------|
| macOS ARM | `macos-14` | `minga_macos_aarch64` |
| macOS Intel | `macos-13` | `minga_macos_x86_64` |
| Linux x86_64 | `ubuntu-latest` | `minga_linux_x86_64` |
| Linux ARM | `ubuntu-24.04-arm` | `minga_linux_aarch64` |

### Homebrew Cask (macOS GUI)

The release workflow also generates a Homebrew cask for the macOS GUI app, but only if a `Minga.dmg` artifact exists in the release. Until the GUI ships `.dmg` builds, the cask step is skipped automatically.

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
```

## Burrito

Minga uses [Burrito](https://github.com/burrito-elixir/burrito) to package the Elixir release as a self-extracting binary. The Burrito dependency is pinned to a specific commit SHA in `mix.exs` for reproducibility. When upgrading Burrito, update both the `ref:` in `mix.exs` and run `mix deps.get` to update `mix.lock`.
