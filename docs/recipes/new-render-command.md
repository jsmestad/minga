# Add a render command

A render command crosses a process boundary. Update the schema and each consumer together so a frontend never interprets a payload using a different field layout.

1. Add the opcode to `docs/protocol_schema.toml`, then run `mix protocol.gen`. Do not hand-edit generated opcode constants.
2. Add the BEAM encoder/decoder behavior in the relevant protocol module under `lib/minga_editor/frontend/` or `lib/minga/parser/`.
3. **macOS GUI:** Use the generated constants from `macos/.generated/protocol/ProtocolOpcodes.generated.swift`, add decoder behavior in `macos/Sources/Protocol/ProtocolDecoder.swift`, and add the handler in `CommandDispatcher.swift`.
4. **TUI:** Use the generated constants from `go/tui/internal/generated/opcodes.go`, then add decoder and handler behavior in the Go renderer under `go/tui/internal/protocol/` and `go/tui/internal/ui/`.
5. **Linux GUI:** (when it exists) Add decoder and handler behavior in the GTK4 frontend.
6. Test encode/decode round-trip on all sides. GUI chrome and semantic opcodes are schema-defined and consumed by the GUI and Go TUI frontends. The `minga-parser` Port (`zig/src/protocol.zig`) also decodes the protocol; if a frontend-only opcode can appear on the parser stream, add an explicit decoder skip or no-op handler for it there.

Shared chrome must follow the root guide's Semantic UI rule: build the model under `lib/minga_editor/render_model/ui/` and encode it under `lib/minga/frontend/adapter/gui/`. Do not add shared chrome to the legacy protocol parity encoders. See [GUI Protocol](../GUI_PROTOCOL.md) for the wire contract and [Charm TUI](../CHARM_TUI.md) for the Go client.

Run the schema contract and Go decoder tests:

```bash
mix test.debug test/minga_editor/frontend/protocol_schema_validation_test.exs
(cd go/tui && go test ./internal/protocol/...)
```

On macOS, rebuild the Swift harness before the round-trip test, then build and test the Swift client:

```bash
mix swift.harness
mix test.debug test/minga_editor/integration/gui_protocol_test.exs
mix swift.build
(cd macos && xcodebuild test -scheme Minga -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO)
```

The GUI round-trip module is excluded when the harness is missing or stale. A green run without a current harness does not prove Swift compatibility. Run `mix zig.lint` when changing the parser decoder.
