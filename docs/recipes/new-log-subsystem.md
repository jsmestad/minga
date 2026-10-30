# Add a log subsystem

Use a subsystem when users need to enable diagnostics for one part of the editor without enabling every debug message. First check the existing eight: `:render`, `:lsp`, `:agent`, `:editor`, `:config`, `:port`, `:distribution`, and `:ext`.

If none fits:

1. Add `:log_level_<name>` to the `option_name` type union in `Minga.Config.Options`.
2. Add a `{:log_level_<name>, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default}` entry to `@option_specs`.
3. Add the subsystem atom to the `@subsystem_options` map in `Minga.Log`.
4. Add the subsystem to the `@type subsystem` union in `Minga.Log`.
5. Document the new subsystem in the Logging section of `docs/CONFIGURATION.md`.

Replace `<name>` with the subsystem name. Test its configured filtering and `:default` inheritance in `test/minga/log_test.exs`, and option validation in `test/minga/config/options_test.exs`:

```bash
mix test.debug test/minga/log_test.exs test/minga/config/options_test.exs
```

Use `Minga.API.message/1` instead when a lifecycle message must appear regardless of diagnostic log levels. See [Configuration](../CONFIGURATION.md#logging) for the user-facing controls.
