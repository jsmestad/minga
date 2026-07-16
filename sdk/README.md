# Minga SDK

Compile-time SDK for building [Minga](https://github.com/jsmestad/minga) editor extensions.

This package provides the types, behaviours, macros, and API stubs that extension authors need to compile their code. At runtime, the real Minga modules in the editor's BEAM VM take over.

## Installation

Add `minga_sdk` to your extension's dependencies:

```elixir
def deps do
  [
    {:minga_sdk, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

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

Extension-owned slow work must use a typed `MingaEditor.Effect` request scheduled by Minga's effect scheduler. Source tagging lets disable cancel in-flight work before presentation cleanup. Custom worker messages to the Editor are not part of the SDK contract.

The runtime and SDK declaration sources are checked for parity in the main Minga test suite. When a runtime DSL macro, generated schema, callback, or callback family changes, the matching SDK declaration must change in the same commit.

## What's included

- `Minga.Extension` behaviour and DSL macros (`option`, `command`, `keybind`, `modeline_segment`, `editor_event_handler`, `load_policy`)
- `Minga.Extension.Agent` declarations for hooks, skills, MCP servers, slash commands, and semantic agent UI
- `Minga.Extension.Overlay` API for rendering positioned overlays on the editor surface
- `Minga.Extension.AgentAPI` for querying agent session state
- `MingaEditor.Extension.EditorAPI` for triggering editor actions from commands
- `Minga.Events` for subscribing to editor events
- `Minga.Buffer` public API types
- `Minga.Buffer.EditSource` and `Minga.Buffer.EditDelta` types for tracking edit origins and positions

See [`EXTENSION_API.md`](../EXTENSION_API.md) for callback ordering, source-owned work, artifact ownership, and update behavior.
