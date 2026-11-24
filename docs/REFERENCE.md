# Minga Reference

Technical manuals, architecture specs, wire protocols, and public Elixir module documentation for configuring and extending Minga.

Looking for installation, guided tours, or interactive exercises instead? Start with [Get Started](https://mingacode.dev/getting-started), walk through the [Interactive Learn Labs](https://mingacode.dev/learn/), or read [Why Minga](https://mingacode.dev/why-minga).

Minga installs from Homebrew on Apple Silicon macOS (the desktop app and the terminal client) and from signed apt, dnf and pacman repositories at `packages.mingacode.dev` on Linux (the terminal client on Arch and Omarchy, Ubuntu 24.04+, Debian 13+ and Fedora). [Get Started](https://mingacode.dev/getting-started#install) has the commands for each.

## Configuration & Agents

- [Configuration](CONFIGURATION.md): Declarative `config.exs` options, keybindings, themes, language servers, and live reload (`SPC h r`).
- [Projects](PROJECTS.md): Project root detection, `.minga.exs` per-repo overrides, file finding, and workspace switching.
- [Hooks](HOOKS.md): Local shell or Elixir lifecycle hooks; `PreToolUse` deterministically gates tool calls by exit code, and `PostToolUse` observes completed calls.
- [Model Context Protocol (MCP)](MCP.md): Configuring supervised stdio MCP servers, prefixed tool discovery, and destructive-call approvals.
- [Remote Agents](REMOTE_AGENTS.md): Running `minga --headless` under `systemd` or `launchd` and attaching over SSH without copying source code.
- [Agent Model Selection](AGENT-MODEL-SELECTION.md): Model routing, per-role provider configuration, and local credential storage.
- [Buffer-Aware Agents](BUFFER-AWARE-AGENTS.md): How agents read live unsaved buffers and stage edits off your working tree before publish.
- [Session Recovery](SESSION-RECOVERY.md): Crash-safe conversation persistence, write-ahead tool logs, and swap recovery.

## Extensions & Keymaps

- [Extension API](EXTENSION_API.md): Building Elixir extensions, custom commands, buffers, tree-sitter grammars, and `MingaAgent.InferenceRoute` model proxies.
- [Keymap Scopes](KEYMAP-SCOPES.md): Scoped keybindings, leader sequences, and mode-aware dispatch rules.
- [Agentic Keymap](AGENTIC-KEYMAP.md): Key conventions for agent buffers, approval drawers, and subagent inspection.

## Public Elixir API

Only modules intended for user configuration, extension authors, and external agent-runtime clients are published here. Internal editor processes and mode state machines live in the repository source.

- **Configuration & Scripting:** `Minga.Config`, `Minga.Config.Options`, `Minga.Config.Hooks`, `Minga.Config.Advice`, `Minga.API`, `Minga.Buffer`, `Minga.Events`
- **Extensions & Languages:** `Minga.Extension`, `Minga.Extension.Editor`, `Minga.Extension.Agent`, `Minga.Extension.AgentAPI`, `Minga.Language`, `Minga.Command`, `Minga.Keymap.Scope`
- **Agent Runtime:** `MingaAgent.Runtime`, `MingaAgent.Introspection`, `MingaAgent.Tool.Spec`, `MingaAgent.Tool.Context`

## Architecture, Protocols & ADRs

- [Architecture](ARCHITECTURE.md): BEAM supervision tree, three-layer dependency boundaries, and multi-frontend isolation.
- [Terminal Protocol](PROTOCOL.md) and [GUI Protocol](GUI_PROTOCOL.md): Binary frame and input contracts between the Elixir core and native frontends.
- [Charm Terminal Frontend](CHARM_TUI.md): Go and Bubble Tea terminal client architecture.
- **Core runtime ADRs:** [ADR-0001](adr/0001-frontend-owns-row-fit.md) (Client Viewport Rows) · [ADR-0002](adr/0002-editor-state-transitions-have-explicit-owners.md) (Explicit State Owners) · [ADR-0003](adr/0003-extension-code-updates-require-a-new-vm-generation.md) (Extension Reloads) · [ADR-0004](adr/0004-products-are-root-applets-over-a-fixed-engine.md) (Task Workflows) · [ADR-0005](adr/0005-frontend-owns-immediate-ui-feedback.md) (Immediate UI Feedback)
- **UI, keys & terminal ADRs:** [ADR-0006](adr/0006-the-spine.md) (The Spine) · [ADR-0007](adr/0007-cua-is-a-key-profile.md) (CUA Key Profile) · [ADR-0008](adr/0008-terminal-engine.md) (Terminal Engine)
- [Changelog](../CHANGELOG.md): Release history and notable changes.

## Repository & Contributor Docs

Contributor guides and internal release tooling live on GitHub rather than in the user reference:

- [Contributing Guide](https://github.com/jsmestad/minga/blob/main/CONTRIBUTING.md)
- [Native Editor Automation IPC](https://github.com/jsmestad/minga/blob/main/docs/AUTOMATION-IPC.md)
- [Releasing Minga](https://github.com/jsmestad/minga/blob/main/docs/RELEASING.md)
