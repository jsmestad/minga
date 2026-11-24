# Agent hooks

Agent hooks let your config run local policy checks around agent tool use. The first implemented event is `PreToolUse`: Minga runs your shell command before a matching agent tool executes, sends JSON about the call on stdin, and treats any non-zero exit as a veto.

## Configure a PreToolUse hook

Add hooks to your Minga config with the `:agent_hooks` option:

```elixir
use Minga.Config

set :agent_hooks, [
  %{
    event: "PreToolUse",
    tool: "shell",
    command: "~/.config/minga/hooks/check-shell-command.sh",
    timeout_ms: 10_000
  }
]
```

`tool` can be an exact tool name, `*` for all tools, or a simple glob with `*` and `?`, such as `*_file`. Hooks run in the order you declare them. The first veto stops later hooks and prevents the tool from running.

`timeout_ms` is optional. The default is `30_000` milliseconds. If a hook exceeds its timeout, Minga blocks the tool call, terminates the POSIX process group it created for the hook, and shows a clear error in the agent chat. Hooks should not launch detached background processes; timeout cleanup is not a sandbox.

## PreToolUse payload

Minga writes one JSON object to the hook command's stdin:

```json
{
  "event": "PreToolUse",
  "tool_call_id": "tc_123",
  "tool_name": "shell",
  "arguments": {
    "command": "git status --short"
  }
}
```

These fields are the public contract for `PreToolUse`:

- `event`: always `PreToolUse` for this event.
- `tool_call_id`: stable ID for this model-requested tool call.
- `tool_name`: the Minga agent tool name, such as `shell`, `read_file`, or `write_file`.
- `arguments`: the exact argument object the tool will receive if the hook allows it.

A zero exit code allows the tool to run. A non-zero exit code blocks the tool. Minga ignores stdout and displays stderr as a system error in the chat, so write user-facing veto reasons to stderr.

## Worked example: block risky shell commands

`~/.config/minga/hooks/check-shell-command.sh`:

```sh
#!/bin/sh
payload=$(cat)

case "$payload" in
  *'"command":"rm -rf /"'*)
    echo "Blocked dangerous shell command: rm -rf /" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
```

Config:

```elixir
use Minga.Config

set :agent_hooks, [
  %{event: "PreToolUse", tool: "shell", command: "~/.config/minga/hooks/check-shell-command.sh"}
]
```

## Event taxonomy

The hook config includes an explicit event name because hooks will cover more agent lifecycle points over time. Minga dispatches every event marked Implemented below. `PreToolUse`, `UserPromptSubmit` and `PreCompact` can veto. The rest only observe: Minga logs a non-zero exit and continues. `SubagentStop` is reserved so config and docs have a stable name for it, but declaring it is rejected until it is implemented.

| Event | Implemented | Can veto | When it runs | Payload fields |
| --- | --- | --- | --- | --- |
| `PreToolUse` | Yes | Yes | Before a matching tool callback executes. | `event`, `tool_call_id`, `tool_name`, `arguments` |
| `PostToolUse` | Yes | No | After a tool completes. | `event`, `tool_call_id`, `tool_name`, `arguments`, `result`, `output`, `is_error` |
| `SessionStart` | Yes | No | When an agent session starts. | `event`, `session_id`, `model`, `provider`, `project_root` |
| `SessionEnd` | Yes | No | When an agent session ends or is cleared. | `event`, `session_id`, `reason`, `status` |
| `UserPromptSubmit` | Yes | Yes | Before a user prompt is sent to the model. | `event`, `session_id`, `prompt` |
| `Stop` | Yes | No | When the main agent turn stops. | `event`, `session_id`, `reason`, `last_message` |
| `SubagentStop` | No | No | When a sub-agent finishes. | `event`, `parent_session_id`, `subagent_session_id`, `result`, `is_error` |
| `PreCompact` | Yes | Yes | Before conversation compaction runs. | `event`, `session_id` (always `null` today), `message_count` |
| `Notification` | Yes | No | When the agent sends a user notification. | `event`, `session_id`, `kind`, `message` |

The payload fields for `SubagentStop` are a planned contract, not a runtime guarantee. Only `PreToolUse` has a worked example in this guide.
