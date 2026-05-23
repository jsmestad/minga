# Extension API

`Minga.Extension.AgentAPI` is the stable, read-only facade that extensions use to query agent session state. Extensions should never import `MingaAgent.Session` or `MingaAgent.SessionManager` directly; the facade shields them from internal refactors while providing a stable map-based contract.

All functions are safe to call with dead PIDs, stopped sessions, or when no session manager is running. They return empty results rather than crashing.

## Listing sessions

`list_sessions/0` returns a summary for every active agent session.

```elixir
sessions = Minga.Extension.AgentAPI.list_sessions()
# => [%{id: "1", pid: #PID<0.1234.0>, status: :thinking, label: "refactor auth",
#       model: "claude-4", active_tool: "edit_file", created_at: ~U[2026-05-23 ...]}]
```

Returns `[]` when no sessions are running or the session manager is unavailable.

## Getting session details

`session_info/1` returns detailed info for a single session, including cost, token usage, turn count, and files touched.

```elixir
case Minga.Extension.AgentAPI.session_info(pid) do
  {:ok, info} ->
    IO.inspect(info.cost)
    IO.inspect(info.files_touched)
    # info keys: id, pid, status, label, model, active_tool, created_at,
    #            cost, input_tokens, output_tokens, turn_count, files_touched

  {:error, :not_found} ->
    IO.puts("Session not found or PID is dead")
end
```

## Subscribing to lifecycle events

`subscribe/0` subscribes the calling process to agent lifecycle events. After subscribing, the process receives messages in the standard event bus format.

```elixir
Minga.Extension.AgentAPI.subscribe()
# The calling process now receives:
# {:minga_event, :agent_session_stopped, %MingaAgent.SessionManager.SessionStoppedEvent{session_id: id, pid: pid, reason: reason}}
# {:minga_event, :agent_hook, %Minga.Events.AgentHookEvent{event: event, phase: phase, tool_name: name, ...}}
```

## Subscribing to edit events

`subscribe_edits/0` subscribes the calling process to all buffer edit events. Filter on the `source` field to isolate agent-originated edits.

```elixir
Minga.Extension.AgentAPI.subscribe_edits()

# To isolate agent edits, pattern-match on the source field inside the struct:
receive do
  {:minga_event, :buffer_changed, %Minga.Events.BufferChangedEvent{source: {:agent, session_pid, tool_call_id}} = event} ->
    # this edit came from an agent session
end
```

## Event message format

All events arrive as three-element tuples:

```elixir
{:minga_event, topic, payload}
```

- `topic` is an atom like `:agent_session_stopped`, `:agent_hook`, or `:buffer_changed`.
- `payload` is a typed struct specific to the topic (see `Minga.Events` for the full list of payload structs).

Extensions should pattern-match on the topic atom and destructure the payload struct to handle events they care about, ignoring the rest.
