# Architecture Diagrams

Interactive diagrams of how Minga's processes, data, and communication are structured.

## Supervision Tree

The BEAM side of Minga uses nested supervisors to constrain blast radius. The top-level `rest_for_one` preserves the Foundation → Buffers → Services → Runtime cascade. Inner supervisors use strategies matched to their children's actual dependency profiles.

### High-level overview

Four tiers, each isolated. A crash in one tier doesn't cascade sideways.

```mermaid
graph TD
    SUP["Minga.Supervisor<br/><i>rest_for_one</i>"]

    SUP --> FOUND["Foundation.Supervisor<br/><i>config, keymaps, events, registries</i>"]
    SUP --> BUFSUP["Buffer.Supervisor<br/><i>one process per open file + git tracking</i>"]
    SUP --> SVC["Services.Supervisor<br/><i>LSP, extensions, diagnostics, agents</i>"]
    SUP --> RT["Runtime.Supervisor<br/><i>renderer, parser, editor orchestration</i>"]

    RT -. "stdin/stdout" .-> ZIG["Zig Processes<br/><i>renderer + parser</i>"]

    style SUP fill:#6c3483,stroke:#4a235a,color:#fff
    style FOUND fill:#6c3483,stroke:#4a235a,color:#fff
    style BUFSUP fill:#1a5276,stroke:#154360,color:#fff
    style SVC fill:#6c3483,stroke:#4a235a,color:#fff
    style RT fill:#b7950b,stroke:#9a7d0a,color:#fff
    style ZIG fill:#1e8449,stroke:#196f3d,color:#fff
```

### Foundation tier

Stateless registries and configuration that everything else depends on. These rarely fail.

```mermaid
graph TD
    FOUND["Foundation.Supervisor<br/><i>rest_for_one</i>"]
    FOUND --> LANG["Language.Registry"]
    FOUND --> EVENTS["Events"]
    FOUND --> OPTS["Config.Options"]
    FOUND --> KEYMAP["Keymap.Active"]
    FOUND --> HOOKS["Config.Hooks"]
    FOUND --> ADVICE["Config.Advice"]
    FOUND --> FT["Filetype.Registry"]

    style FOUND fill:#6c3483,stroke:#4a235a,color:#fff
```

### Buffer tier

One process per open file, plus per-buffer git tracking. `one_for_one` means each buffer is independent: one crashing doesn't affect any other.

```mermaid
graph TD
    BUFSUP["Buffer.Supervisor<br/><i>DynamicSupervisor, one_for_one</i>"]
    BUFSUP --> B1["Buffer: main.ex"]
    BUFSUP --> B2["Buffer: router.ex"]
    BUFSUP --> B3["Buffer: schema.ex"]
    BUFSUP --> GB1["Git.Buffer: main.ex"]
    BUFSUP --> GB2["Git.Buffer: router.ex"]
    BUFSUP --> BF1["Buffer.Fork: main.ex<br/><i>(agent session A)</i>"]

    style BUFSUP fill:#1a5276,stroke:#154360,color:#fff
    style B1 fill:#2471a3,stroke:#1a5276,color:#fff
    style B2 fill:#2471a3,stroke:#1a5276,color:#fff
    style B3 fill:#2471a3,stroke:#1a5276,color:#fff
    style GB1 fill:#2471a3,stroke:#1a5276,color:#fff
    style GB2 fill:#2471a3,stroke:#1a5276,color:#fff
    style BF1 fill:#2471a3,stroke:#1a5276,color:#fff,stroke-dasharray: 5 5
```

> **Note:** `Buffer.Fork` processes (dashed border) are planned. See [Buffer-Aware Agents](BUFFER-AWARE-AGENTS.md#phase-2-buffer-forking-with-three-way-merge).

### Services tier

Higher-level features that depend on Foundation and Buffers. A git tracking crash restarts only Git.Tracker. An LSP server crash restarts only that client.

```mermaid
graph TD
    SVC["Services.Supervisor<br/><i>rest_for_one</i>"]
    SVC --> INDEP["Services.Independent<br/><i>one_for_one</i>"]
    INDEP --> GIT["Git.Tracker"]
    INDEP --> TASKSUP["Eval.TaskSupervisor"]
    INDEP --> CMDREG["Command.Registry"]
    INDEP --> DIAG["Diagnostics"]
    SVC --> EXTREG["Extension.Registry"]
    SVC --> EXTSUP["Extension.Supervisor"]
    SVC --> LOADER["Config.Loader"]
    SVC --> LSPSUP["LSP.Supervisor<br/><i>DynamicSupervisor</i>"]
    LSPSUP --> LSP1["LSP Client: elixir-ls"]
    LSPSUP --> LSP2["LSP Client: lua-ls"]
    SVC --> SYNC["LSP.SyncServer"]
    SVC --> PROJ["Project"]
    SVC --> AGENTSUP["Agent.Supervisor<br/><i>DynamicSupervisor</i>"]
    AGENTSUP --> AS1["Agent.Session<br/><i>Claude (refactoring)</i>"]
    AGENTSUP --> AS2["Agent.Session<br/><i>Claude (tests)</i>"]

    style SVC fill:#6c3483,stroke:#4a235a,color:#fff
    style INDEP fill:#6c3483,stroke:#4a235a,color:#fff
    style LSPSUP fill:#1a5276,stroke:#154360,color:#fff
    style AGENTSUP fill:#1a5276,stroke:#154360,color:#fff
    style TASKSUP fill:#1a5276,stroke:#154360,color:#fff
    style AS1 fill:#884ea0,stroke:#6c3483,color:#fff
    style AS2 fill:#884ea0,stroke:#6c3483,color:#fff
    style LSP1 fill:#2471a3,stroke:#1a5276,color:#fff
    style LSP2 fill:#2471a3,stroke:#1a5276,color:#fff
```

### Runtime tier

The tightly-coupled trio that handles rendering and user interaction. If the Port Manager (renderer) fails, the Editor restarts too since it depends on the renderer. Buffers stay untouched.

```mermaid
graph TD
    RT["Runtime.Supervisor<br/><i>one_for_one</i>"]
    RT --> WD["Editor.Watchdog"]
    RT --> FW["FileWatcher"]
    RT --> EDSUP["Editor.Supervisor<br/><i>rest_for_one</i>"]
    EDSUP --> PARSER["Parser.Manager"]
    EDSUP --> PM["Port.Manager"]
    EDSUP --> ED["Editor"]

    PM -. "stdin/stdout<br/>Port protocol" .-> ZIG_R["minga-renderer<br/><i>Zig + libvaxis</i>"]
    PARSER -. "stdin/stdout<br/>Port protocol" .-> ZIG_P["minga-parser<br/><i>Zig + tree-sitter</i>"]

    style RT fill:#b7950b,stroke:#9a7d0a,color:#fff
    style EDSUP fill:#6c3483,stroke:#4a235a,color:#fff
    style PM fill:#b7950b,stroke:#9a7d0a,color:#fff
    style ED fill:#b7950b,stroke:#9a7d0a,color:#fff
    style WD fill:#b7950b,stroke:#9a7d0a,color:#fff
    style FW fill:#b7950b,stroke:#9a7d0a,color:#fff
    style ZIG_R fill:#1e8449,stroke:#196f3d,color:#fff
    style ZIG_P fill:#1e8449,stroke:#196f3d,color:#fff
```

## Two-Process Architecture

Minga splits into two OS processes with completely isolated memory. The BEAM handles all editor logic; the Zig process handles terminal I/O and syntax parsing.

```mermaid
graph LR
    subgraph BEAM["BEAM (Elixir)"]
        ED2["Editor<br/>orchestration"]
        BUF["Buffer<br/>GenServers"]
        CMD["Commands &<br/>Keymaps"]
        MODE["Mode FSM<br/>normal/insert/visual"]
        PORT["Port.Manager"]

        ED2 <--> BUF
        ED2 <--> CMD
        ED2 <--> MODE
        ED2 --> PORT
    end

    subgraph ZIG["Zig + libvaxis"]
        EVLOOP["Event Loop"]
        PROTO["Protocol<br/>decoder/encoder"]
        RENDER["Renderer<br/>cell grid"]
        TS["Tree-sitter<br/>parser"]
        TTY["/dev/tty<br/>terminal I/O"]

        EVLOOP <--> PROTO
        EVLOOP <--> RENDER
        EVLOOP <--> TS
        RENDER <--> TTY
    end

    PORT -- "render commands<br/>(draw_text, set_cursor, clear)" --> PROTO
    PROTO -- "input events<br/>(key_press, resize, highlights)" --> PORT

    style BEAM fill:#1a1a2e,stroke:#6c3483,color:#fff
    style ZIG fill:#1a2e1a,stroke:#1e8449,color:#fff
```

## Life of a Keystroke

What happens when you press `dd` (delete a line) in normal mode. The entire round-trip takes under 1ms on the BEAM side.

```mermaid
sequenceDiagram
    participant Term as Terminal
    participant Zig as Zig Process
    participant PM as Port.Manager
    participant Ed as Editor
    participant Mode as Mode.Normal
    participant Buf as Buffer.Server

    Term->>Zig: raw key bytes
    Zig->>Zig: libvaxis decodes key
    Zig->>PM: key_press(0x01) via stdout

    Note over Ed,Mode: First 'd'
    PM->>Ed: {:key_event, :d}
    Ed->>Mode: handle_key(:d)
    Mode-->>Ed: {:pending, :operator_pending}
    Ed->>Ed: transition to OperatorPending

    Note over Ed,Buf: Second 'd'
    PM->>Ed: {:key_event, :d}
    Ed->>Mode: handle_key(:d)
    Mode-->>Ed: {:execute, :delete_line}
    Ed->>Buf: Operator.delete_line()
    Buf->>Buf: update gap buffer + push undo

    Note over Ed,Term: Render cycle
    Ed->>Ed: build render snapshot
    Ed->>PM: [clear, draw_text x N, set_cursor, batch_end]
    PM->>Zig: render commands via stdin
    Zig->>Zig: update cell grid (double-buffered)
    Zig->>Term: write changed cells
```

## Port Protocol

Length-prefixed binary messages over stdin/stdout. Each message is a 4-byte big-endian length, a 1-byte opcode, then opcode-specific fields.

```mermaid
graph LR
    subgraph ZigToBEAM["Zig → BEAM"]
        K["0x01 Key Press<br/>codepoint::32, mods::8"]
        R["0x02 Resize<br/>width::16, height::16"]
        RDY["0x03 Ready<br/>width::16, height::16"]
        M["0x04 Mouse<br/>row, col, button, mods, type"]
        HS["0x30 Highlight Spans<br/>version, count, [start, end, id]"]
        HN["0x31 Highlight Names<br/>count, [len, name]"]
        GL["0x32 Grammar Loaded<br/>success, name"]
    end

    subgraph BEAMToZig["BEAM → Zig"]
        DT["0x10 Draw Text<br/>row, col, fg, bg, attrs, text"]
        SC["0x11 Set Cursor<br/>row::16, col::16"]
        CL["0x12 Clear"]
        BE["0x13 Batch End<br/>(flush frame)"]
        CS["0x15 Cursor Shape<br/>block/beam/underline"]
        SL["0x20 Set Language"]
        PB["0x21 Parse Buffer"]
        SH["0x22 Set Highlight Query"]
        LG["0x23 Load Grammar"]
    end

    style ZigToBEAM fill:#1a2e1a,stroke:#1e8449,color:#fff
    style BEAMToZig fill:#1a1a2e,stroke:#6c3483,color:#fff
```

## Syntax Highlighting Pipeline

Tree-sitter runs in the Zig process. The BEAM controls what to parse and how to color it; Zig does the actual parsing and returns highlight spans.

```mermaid
sequenceDiagram
    participant Ed as Editor
    participant PM as Port.Manager
    participant Zig as Zig Process
    participant TS as Tree-sitter

    Note over Ed: File opened, filetype detected
    Ed->>PM: set_language("elixir")
    PM->>Zig: 0x20 Set Language

    Ed->>PM: parse_buffer(version, content)
    PM->>Zig: 0x21 Parse Buffer
    Zig->>TS: parse with grammar
    TS-->>Zig: syntax tree
    Zig->>Zig: run highlight query

    Zig->>PM: 0x31 highlight_names
    Zig->>PM: 0x30 highlight_spans
    PM->>Ed: spans + capture names

    Note over Ed: Map captures → theme colors
    Ed->>Ed: slice visible lines at span boundaries
    Ed->>PM: draw_text with per-segment colors
    PM->>Zig: 0x10 Draw Text commands
    Zig->>Zig: render colored text to terminal
```

## Buffer Architecture

Each buffer wraps a gap buffer: two binaries with a gap at the cursor. Insertions at the cursor are O(1).

```mermaid
graph TD
    subgraph Document["Gap Buffer Internals"]
        direction LR
        BEFORE["before: &quot;Hello&quot;"]
        GAP["◄ cursor ►"]
        AFTER["after: &quot;, world!&quot;"]
        BEFORE --- GAP --- AFTER
    end

    subgraph Operations["O(1) Operations"]
        INS["Insert 'X' at cursor<br/>before → &quot;HelloX&quot;<br/>after unchanged"]
        DEL["Delete before cursor<br/>before → &quot;Hell&quot;<br/>after unchanged"]
    end

    Document --> Operations

    style Document fill:#1a1a2e,stroke:#6c3483,color:#fff
    style Operations fill:#1a2e1a,stroke:#1e8449,color:#fff
```
