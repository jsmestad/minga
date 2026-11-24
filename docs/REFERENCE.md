# Minga Reference

This is the index of Minga's reference docs. It is for people who have Minga running and want to look something up: change a setting, pick a model, leave an agent working on its own, write an extension, or find out how the editor works underneath. The guides are grouped by what you are trying to do, in the same order as the sidebar.

New to Minga? Read in this order:

1. **[Get Started](https://mingacode.dev/getting-started):** install Minga, connect a model, and review your first staged edit.
2. **[Learn](https://mingacode.dev/learn/):** hands-on lessons that pick up where Get Started ends.
3. **This reference, by task:** look up what you need when you need it. Every published doc is listed below.

Still deciding whether Minga fits how you work? Read [Why Minga](https://mingacode.dev/why-minga).

Minga installs from Homebrew on Apple Silicon macOS (the desktop app and the terminal client) and from signed apt, dnf and pacman repositories at `packages.mingacode.dev` on Linux (the terminal client on Arch and Omarchy, Ubuntu 24.04+, Debian 13+ and Fedora). [Get Started](https://mingacode.dev/getting-started#install) has the commands for each.

## Use Minga

Day-to-day guides for making Minga yours.

- [Configuration](CONFIGURATION.md): Set options, keys, themes and language tools in `config.exs`, and reload them with `SPC h r`.
- [Projects](PROJECTS.md): How Minga finds your project root, per-repo overrides in `.minga.exs`, file finding, and switching projects.
- [Agent Model Selection](AGENT-MODEL-SELECTION.md): Choose the model the agent runs on, switch models in the middle of a conversation, and connect provider credentials.
- [Agentic Keymap](AGENTIC-KEYMAP.md): The keys for the agent view, approvals, and publishing or discarding the agent's edits.

## Run Agents Unattended

Guides for leaving an agent to work while you do something else, with your rules still applied.

- [Hooks](HOOKS.md): Run your own shell command at points in the agent's work. `PreToolUse`, `UserPromptSubmit` and `PreCompact` can veto, and the other events observe. The event table in that guide is the list of what runs today.
- [Model Context Protocol (MCP)](MCP.md): Give the agent tools from MCP servers, with approval before destructive calls.
- [Remote Agents](REMOTE_AGENTS.md): Keep agents running on a server with `minga --headless`, then attach over SSH from any machine.

## Extend Minga

For when configuration is not enough and you want to add something new.

- [Extension API](EXTENSION_API.md): Write an Elixir extension, starting from a single file, then add commands, keys, languages, tree-sitter grammars and model routes.

### Public Elixir API

Only modules intended for user configuration, extension authors, and external agent-runtime clients are published here. Internal editor processes and mode state machines live in the repository source.

- **Configuration & Scripting:** `Minga.Config`, `Minga.Config.Options`, `Minga.Config.Hooks`, `Minga.Config.Advice`, `Minga.API`, `Minga.Buffer`, `Minga.Events`
- **Extensions & Languages:** `Minga.Extension`, `Minga.Extension.Editor`, `Minga.Extension.Agent`, `Minga.Extension.AgentAPI`, `Minga.Language`, `Minga.Command`, `Minga.Keymap.Scope`
- **Agent Runtime:** `MingaAgent.Runtime`, `MingaAgent.Introspection`, `MingaAgent.Tool.Spec`, `MingaAgent.Tool.Context`

## How It Works

Guides to what Minga does underneath. You do not need them to use Minga; read them when you want to know why it behaves the way it does, or when you build a frontend.

- [Architecture](ARCHITECTURE.md): Why a slow or broken part does not freeze the editor: separate processes, supervision, and one core that every frontend draws from.
- [Buffer-Aware Agents](BUFFER-AWARE-AGENTS.md): How agents read your unsaved buffers and stage their edits away from your working tree until you publish.
- [Session Recovery](SESSION-RECOVERY.md): How agent conversations survive a crash or a restart, and what is restored.
- [Keymap Scopes](KEYMAP-SCOPES.md): How Minga decides which keys are active in each kind of view.
- [Terminal Protocol](PROTOCOL.md) and [GUI Protocol](GUI_PROTOCOL.md): The messages the editor core and the frontends exchange. Read these to build or debug a frontend.
- [Charm Terminal Frontend](CHARM_TUI.md): How the terminal client is built, run and tested.

## Design System

How Minga looks and behaves on every frontend. [ADR-0006](adr/0006-the-spine.md) records the decision; these pages hold the rules a builder needs.

- [Minga design](design/README.md): The overview and the order to read the design pages in.
- [Principles](design/principles.md): The eleven rules that win when a mockup or a shortcut disagrees with them.
- [Marks](design/marks.md): The two marks that make Minga look like Minga.
- [Themes and colour roles](design/themes.md): How every colour on screen comes from the user's theme.
- [Keys](design/keys.md): Every key the v0.1.0 design adds, changes or retires, compared with today's keymap.
- [Surfaces](design/surfaces.md): The resting screen and the buffers that appear when you ask for them.
- [Surface anatomy](design/anatomy.md): Spacing, alignment and polish for each surface.
- [The built-in terminal](design/terminal.md): The interaction contract for terminal buffers.
- [The terminal UI](design/tui.md): How the Go TUI draws the same screens as macOS.
- [Storyboard](design/storyboard.md): The executable scenarios that keep both frontends on one design.
- [Visual review rubric](design/visual_rubric.md): How a pull request that changes a scenario's look is reviewed.

## Decisions

The architecture decision records (ADRs) say why Minga is built the way it is, one decision per page.

- **Core runtime:** [ADR-0001](adr/0001-frontend-owns-row-fit.md) (Client Viewport Rows) · [ADR-0002](adr/0002-editor-state-transitions-have-explicit-owners.md) (Explicit State Owners) · [ADR-0003](adr/0003-extension-code-updates-require-a-new-vm-generation.md) (Extension Reloads) · [ADR-0004](adr/0004-products-are-root-applets-over-a-fixed-engine.md) (Task Workflows) · [ADR-0005](adr/0005-frontend-owns-immediate-ui-feedback.md) (Immediate UI Feedback)
- **UI, keys and terminal:** [ADR-0006](adr/0006-the-spine.md) (The Spine) · [ADR-0007](adr/0007-cua-is-a-key-profile.md) (CUA Key Profile) · [ADR-0008](adr/0008-terminal-engine.md) (Terminal Engine)

## Release History

- [Changelog](../CHANGELOG.md): Release history and notable changes.

## Contributor Docs

Docs for people working on Minga itself are not published here. They live in the repository, and the [Contributing Guide](https://github.com/jsmestad/minga/blob/main/CONTRIBUTING.md) is their index. It links to:

- Performance gates (`docs/PERFORMANCE.md`)
- Snapshot testing (`docs/SNAPSHOT_TESTING.md`)
- The macOS launched-app accessibility test (`docs/MACOS_ACCESSIBILITY_TESTING.md`)
- Preparing and verifying builds (`docs/RELEASING.md`)
- Native editor automation over `minga-ipc` (`docs/AUTOMATION-IPC.md`)
- Step-by-step recipes for adding commands, motions, text objects, agent tools, render commands and grammars (`docs/recipes/`)
