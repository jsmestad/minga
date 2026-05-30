# hello-world plugin

A minimal example plugin using the JSON manifest format (`plugin.json`).

## Components

- **Hook:** `session_start` hook that prints a greeting
- **Skill:** `greet` skill with simple greeting instructions

## Install

Symlink or copy this directory into your plugin directory:

    # User-scoped (available in all projects)
    ln -s /path/to/examples/plugins/hello-world ~/.config/minga/plugins/hello-world

    # Project-scoped (available only in this project)
    mkdir -p .minga/plugins
    ln -s /path/to/examples/plugins/hello-world .minga/plugins/hello-world

Restart Minga or run `SPC h r` to reload.

## Uninstall

Remove the symlink. Components are cleaned up on the next session start.
