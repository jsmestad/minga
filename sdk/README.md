# Minga SDK

Compile-time SDK for building [Minga](https://github.com/jsmestad/minga) editor extensions.

This package provides the types, behaviours, macros, and API stubs that extension authors need to compile their code. At runtime, the real Minga modules in the editor's BEAM VM take over.

The full extension guide lives in the Minga repository: [Extension API](https://github.com/jsmestad/minga/blob/main/docs/EXTENSION_API.md) covers every callback, declaration macro, lifecycle boundary, and API with examples. Module documentation for this package is on [HexDocs](https://hexdocs.pm/minga_sdk).

## Installation

Add `minga_sdk` to your extension's dependencies exactly like this:

```elixir
def deps do
  [
    {:minga_sdk, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

Both options matter. The SDK only defines compile-time stubs of modules the editor already has, so it must never be loaded next to the real ones. `only: [:dev, :test]` keeps it out of your extension when Minga installs it, and `runtime: false` keeps it out of your release. As a second safeguard, the SDK compiles no modules at all when it is built inside a running Minga editor.

## Compatibility

| minga_sdk | Minga |
|-----------|-------|
| 0.1.2 | First rolling Minga build after [#3819](https://github.com/jsmestad/minga/pull/3819), which adds the source-owned picker, prompt, and Git workflow APIs |
| 0.1.1 | Minga builds with the extension notice API (#3764) |
| 0.1.0 | `main` from jsmestad/minga#3756 (model routes with setup rows and plan usage) onward; the first rolling build after that merge and later |

The SDK is versioned separately from Minga. New SDK APIs can require a newer Minga build, even within the same minor SDK series.

## Usage

```elixir
defmodule MyExtension do
  use Minga.Extension

  option :enabled, :boolean, default: true, description: "Enable the extension"

  command :my_command, "Does something useful",
    execute: {MyExtension.Commands, :run}

  keybind :normal, "SPC m x", :my_command, "Run my command"

  @impl true
  def name, do: :my_extension

  @impl true
  def description, do: "My cool extension"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config), do: {:ok, %{}}
end
```

## Lifecycle contract

Minga admits one complete validated artifact inventory for an extension source and keeps that code resident for the lifetime of the BEAM OS process. Disabling and restarting an extension stop its runtime and remove its source-owned contributions, but they do not unload modules. Editing path extension source, updating a Git extension, or changing a compiled user module takes effect only after a fresh Minga process starts.

Each extension has one stable lifecycle authority. It runs `init/1`, starts the child from `child_spec/1`, registers contributions, and only then publishes the runtime as running. The `restart` value on your top-level child spec is honored by that authority: `:permanent` restarts after any terminal exit, `:transient` only after abnormal exits, and `:temporary` never restarts. Minga starts the top-level runtime child as temporary internally so OTP and the lifecycle authority cannot both restart it.

```elixir
def child_spec(config) do
  Supervisor.child_spec({MyExtension.Supervisor, config}, restart: :transient)
end
```

Runtime callbacks are declared with `editor_event_handler/3`. The supported families are `:buffer_saved`, `:editor_action`, and `:source_unload`. Callback exceptions, exits, unavailable code, and invalid returns are reported as explicit extension failures. A `:source_unload` callback runs during disable after new callback work is closed and before the runtime child and source contributions are removed. Keep it bounded and do not synchronously call extension start or stop from it.

Keep slow work out of callbacks. Run it in your extension's own supervised processes, started from `child_spec/1`, and publish results through the SDK APIs such as panels, overlays, badges, and sidebar snapshots. Minga cancels that work when your extension is disabled by stopping its runtime. Custom messages to the Editor process are not part of the SDK contract.

The engine and the standalone SDK compile the same declaration modules from `sdk/lib/declarations`. The standalone SDK also compiles API stubs that the engine does not use. The engine and SDK keep separate editor event-handler behaviours; the engine test suite checks that their callback families and signatures agree.

## Model routes

A model route lets your extension add models to `/model` while Minga keeps running the agent turn: tools, approvals, retries, compaction, and history stay in Minga, and your route only streams model output. Register it from `init/1` and keep the returned reporter:

```elixir
def init(_config) do
  {:ok, reporter} =
    Minga.Extension.ModelRoutes.register(
      id: "company_proxy",
      module: CompanyProxy.Route,
      display_name: "Company Proxy"
    )

  {:ok, %{reporter: reporter}}
end
```

Minga checks your route's `availability/2` when the user opens `/model`. When your extension learns about a change itself, for example right after the user signs in, report it through the reporter from any process:

```elixir
Minga.Extension.ModelRoutes.report_status(reporter, {:ready, "me@example.com"})
```

Subscription routes can do more. Pass `short_name:` (for example `"Claude"`) to name the route inside sentences such as "Claude plan limit reached.", and `setup_action:` with a `label` and `description` to show a setup row in `/model` that runs your `availability/2` check and shows your remedy text. When your route learns how much of a plan's limit windows is used, report it with `report_usage/2`; Minga shows it on the model's row and names the reset time when a limit is reached:

```elixir
Minga.Extension.ModelRoutes.report_usage(reporter, [
  %{kind: "five_hour", utilization: 0.82, resets_at: resets_at, status: :warning}
])
```

Report an empty list when you have no usage data; Minga then shows nothing. Until a ready route that offers subscription models makes its first report, `/model` says its plan usage is being checked, so report an empty list when a usage check fails too.

`CompanyProxy.Route` implements the `MingaAgent.InferenceRoute` behaviour: `models/1`, `availability/2`, `stream/1`, and `classify_error/1`. The route contract uses only Minga-owned values, so it stays stable when Minga changes its internal model library. See [Model routes](https://github.com/jsmestad/minga/blob/main/docs/EXTENSION_API.md#model-routes) for a complete route.

## What's included

- `Minga.Extension` behaviour and DSL macros (`option`, `command`, `keybind`, `modeline_segment`, `editor_event_handler`, `load_policy`)
- `Minga.Extension.Agent` declarations for hooks, skills, MCP servers, slash commands, and semantic agent UI
- `Minga.Extension.Overlay`, `Minga.Extension.Panel`, and `Minga.Extension.Badge` for overlays, panels, and file tree and tab badges
- `MingaEditor.Extension.Sidebar` for sidebar contributions
- `Minga.Extension.Storage`, `Minga.Extension.Diagnostics`, and `Minga.Extension.AI` for per-extension storage, diagnostics, and text generation
- `Minga.Extension.Manifest` for the declaration snapshot of an extension
- `Minga.Extension.AgentAPI` for querying agent session state
- `MingaEditor.Extension.EditorAPI` for triggering editor actions from commands
- `Minga.Events` for subscribing to editor events
- `Minga.Buffer` public API types
- `Minga.Buffer.EditSource` and `Minga.Buffer.EditDelta` types for tracking edit origins and positions
- `Minga.Extension.ModelRoutes` and the `MingaAgent.InferenceRoute` contract for model routes

See the [Extension API guide](https://github.com/jsmestad/minga/blob/main/docs/EXTENSION_API.md) for callback ordering, source-owned work, artifact ownership, and update behavior.
