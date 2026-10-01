# Changelog

All notable changes to Minga are documented here. This file is automatically updated by the release pipeline when a new version is published.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Changed

- Agent tool advice now carries tool results through an explicit tagged invocation outcome. Tool-specific around callbacks must return `{:returned, state, result}` or `{:skipped, state}`; editor command advice keeps its existing state-to-state contract.
- Native agent tool effects now require a durable provider-continuation checkpoint and single-attempt admission; interrupted admitted calls recover as explicit indeterminate results without replay.
- Native agent model changes now resolve an exact model, wire protocol, endpoint, credential profile, reasoning controls, limits, and capabilities before activation. The model picker shows route verification and favorites, and saved sessions restore the same secret-free route identity without credential fallback.

<!-- RELEASE_MARKER: new releases are prepended above this line -->
