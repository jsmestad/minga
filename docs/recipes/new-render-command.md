# Add a render command

1. Edit `docs/protocol_schema.toml`.
2. Run `mix protocol.gen`.
3. Fix what fails. Consumer contracts are generated in `macos/.generated/protocol/ProtocolConsumers.generated.swift` and `go/tui/internal/generated/consumers.go`; opcode constants are generated in `macos/.generated/protocol/ProtocolOpcodes.generated.swift` and `go/tui/internal/generated/opcodes.go`.
