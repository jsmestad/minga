# Changelog

All notable changes to Minga are documented here. This file is automatically updated by the release pipeline when a new version is published.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Changed

- Ordinary editor startup defers agent model discovery until agent use and starts the bundled BEAM before native font and Metal setup. Unresolved models retain truthful readiness, credential-free profiles skip implicit catalog discovery, and explicitly selected local/custom routes remain available. Exact route startup preserves the selected reasoning policy.
- Agent tool advice now carries tool results through an explicit tagged invocation outcome. Tool-specific around callbacks must return `{:returned, state, result}` or `{:skipped, state}`; editor command advice keeps its existing state-to-state contract.
- Native agent tool effects now require a durable provider-continuation checkpoint and single-attempt admission; interrupted admitted calls recover as explicit indeterminate results without replay.
- Native agent model changes now resolve an exact model, wire protocol, endpoint, credential profile, reasoning controls, limits, and capabilities before activation. The model picker and slash completion expose exact route evidence; unsupported tool, image, and thinking requests are rejected before transport; and saved sessions restore the same secret-free route identity without credential fallback. See `docs/AGENT-MODEL-SELECTION.md`.
- Native agent reads, discovery, searches, shell results, and tool results now distinguish visible truncation from bounded durable capture, support binary-safe exact record-scoped retrieval across restart, preserve source revisions and timeout prefixes, reconcile interrupted delivery outputs without replay, and explicitly refuse retention quota failures. Image reads deliver retained bytes through exact model and protocol support or return a visible limitation before full capture. Combined snapshots preserve output ownership and migrate separate model-selection and retained-output records safely.

### Fixed

- Bounded agent command collection now terminates live producers before closing their Ports on timeout or capture exhaustion. Search and shell commands no longer continue consuming CPU after returning an incomplete result.

<!-- RELEASE_MARKER: new releases are prepended above this line -->
