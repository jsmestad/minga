# Changelog

All notable changes to `minga_sdk` are documented here. The SDK is versioned separately from Minga; see the compatibility table for which Minga builds each release supports.

## Compatibility

| minga_sdk | Minga |
|-----------|-------|
| 0.1.x | `main` from jsmestad/minga#3756 (model routes with setup rows and plan usage) onward; the first rolling build after that merge and later |

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
