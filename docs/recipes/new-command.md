# Add a command

Put a new editor action in the command provider that owns its behavior, then bind it in the scopes where it should run. Commands trust keymap dispatch; do not add context guards inside the command.

1. Add the command to the appropriate `MingaEditor.Commands.*` module's `__commands__/0`, which implements `Minga.Command.Provider`. Include its name, description, `requires_buffer` flag, and execute function. If no existing provider fits, create one and add it to `@command_modules` in `lib/minga/command/registry.ex`.
2. Add the default keybinding in `lib/minga/keymap/defaults.ex`. For scope-specific bindings, follow [Keymap Scopes](../KEYMAP-SCOPES.md).
3. Test the command's observable behavior in its command test under `test/minga_editor/commands/`. Cover registration in `test/minga/command/registry_test.exs` and key lookup in `test/minga/keymap/defaults_test.exs`.

Run the command's focused test and these registration checks from the repository root:

```bash
mix test.debug test/minga/command/registry_test.exs test/minga/keymap/defaults_test.exs
```
