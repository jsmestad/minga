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

## What's included

- `Minga.Extension` behaviour and DSL macros (`option`, `command`, `keybind`, `modeline_segment`)
- `Minga.Extension.Overlay` API for rendering positioned overlays on the editor surface
- `Minga.Extension.AgentAPI` for querying agent session state
- `MingaEditor.Extension.EditorAPI` for triggering editor actions from commands
- `Minga.Events` for subscribing to editor events
- `Minga.Buffer` public API types
- `Minga.Buffer.EditSource` and `Minga.Buffer.EditDelta` types for tracking edit origins and positions
