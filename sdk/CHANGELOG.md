# Changelog

All notable changes to `minga_sdk` are documented here. The SDK is versioned separately from Minga; see the compatibility table for which Minga builds each release supports.

## Compatibility

| minga_sdk | Minga |
|-----------|-------|
| 0.1.2 | First rolling Minga build after [#3819](https://github.com/jsmestad/minga/pull/3819), which adds the source-owned picker, prompt, and Git workflow APIs |
| 0.1.1 | Minga builds with the extension notice API and optional extension support (#3764) |
| 0.1.0 | `main` from jsmestad/minga#3756 (model routes with setup rows and plan usage) onward; the first rolling build after that merge and later |

## Unreleased

- `MingaAgent.InferenceRoute.Status.plan_usage` is `:unreported` until the route's first usage report, then the reported windows or nil. `/model` shows a ready subscription route's plan usage as being checked until that first report, so a route should report an empty list when its usage check finds no data or fails.
- `MingaEditor.Extension.Picker.Item.two_line` is accepted for compatibility and no longer changes the row layout. Frontends choose it.

## 0.1.2

- Open pickers and prompts from extension commands with captured arguments and source-owned callbacks. The editor handles presentation, pagination, dismissal, and unload.
- Use `Minga.Git` for explicit repository operations and versioned tracked-buffer snapshots. Index reads distinguish a missing entry from an empty file or a read failure. Stage one selected change without staging unrelated changes.
- Use `MingaEditor.Extension.GitStatus` and `GitDiff` to present Git workflows in the host. Use `RepositoryJob` for work that must run outside the editor process.
- Resolve conflicts and save or replace buffer text at a specific version.

## 0.1.1

### Added

- `MingaEditor.Extension.EditorAPI.notice/2` shows a transient editor notice from an extension command.
- `Minga.Config.get_extension_option/2` lets standalone extensions compile against the public extension option reader.

### Fixed

- The compiler no longer infers that runtime editor calls cannot return from the SDK's compile-time guards.

## 0.1.0

First release published to Hex.

### Added

- `Minga.Extension.ModelRoutes` and the `MingaAgent.InferenceRoute` behaviour, with its Minga-owned request, response, event, and status values, so extensions can add model routes that run inside Minga's agent turn.
- Subscription route support: `Minga.Extension.ModelRoutes.report_usage/3` with `MingaAgent.InferenceRoute.PlanWindow` values for plan usage (`Status.plan_usage`), an optional `setup_action` (`MingaAgent.InferenceRoute.SetupAction`) that shows a setup row in `/model`, and an optional `short_name` on the route spec for sentences such as "Claude plan limit reached."
- `MingaEditor.Extension.EditorAPI.active_buffer/1`, matching the editor.
- `Minga.Extension.AgentAPI.list_sessions/1` and `session_info/2` accept the same options as the editor.

### Changed

- The SDK compiles no modules when it is built inside a running Minga editor, so a Hex extension installed by the editor can never replace real editor modules with stubs.
- Declare the dependency as `{:minga_sdk, "~> 0.1", only: [:dev, :test], runtime: false}`.
- Requires Elixir 1.18 or later.

### Removed

- The `set_status/2` stub on `MingaEditor.Extension.EditorAPI`. The editor never provided it, so extensions that called it failed at runtime.
