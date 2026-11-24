#!/usr/bin/env bash
# Build signed repositories from fixture release assets with a throwaway key,
# then install from them on Ubuntu, Debian, Fedora and Arch.
#
# Requires Docker, dpkg-deb and rpmbuild. Run from the repository root.
set -euo pipefail

version=0.1.0-dev.7
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 -B test/scripts/package_repo_fixtures.py "$work/assets" "$version"

export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-generate-key 'Minga Test <test@invalid>' rsa3072 sign never
gpg --batch --pinentry-mode loopback --passphrase '' --armor --export-secret-keys > "$work/key.asc"
gpgconf --kill gpg-agent

scripts/build-package-repos "$work/assets" "$version" "$(git rev-parse HEAD)" "$work/key.asc" "$work/tree" > /dev/null
scripts/test-package-repos "$work/tree" "$version"
