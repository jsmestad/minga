# hello-elixir plugin

A minimal example plugin using the Elixir extension format (`use Minga.Extension.Agent`).

## Components

- **Hook:** `session_start` hook that prints a greeting
- **Slash command:** `/greet_elixir` runs the greeting script

## Install

Symlink or copy this directory into your plugin directory:

    # User-scoped
    ln -s /path/to/examples/plugins/hello-elixir ~/.config/minga/plugins/hello-elixir

    # Project-scoped
    mkdir -p .minga/plugins
    ln -s /path/to/examples/plugins/hello-elixir .minga/plugins/hello-elixir

Restart Minga or run `SPC h r` to reload.

## Uninstall

Remove the symlink. Components are cleaned up on the next session start.
