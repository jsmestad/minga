# Extension API

`Minga.Extension.AgentAPI` is the stable, read-only facade that extensions use to query agent session state. Extensions should never import `MingaAgent.Session` or `MingaAgent.SessionManager` directly; the facade shields them from internal refactors while providing a stable map-based contract.

All functions are safe to call with dead PIDs, stopped sessions, or when no session manager is running. They return empty results rather than crashing.

## Extension code activation

Path and Git extensions compile only in a standalone disposable BEAM OS process. Its standard streams are bounded, discarded byte data rather than an ETF-capable host control channel. Source is bounded and copied into a private immutable snapshot before hashing or compilation. A second standalone process structurally validates bounded BEAM/ETF data and writes a descriptor-verified UTF-8 report before the host creates atoms or loads code. The complete validated BEAM artifact set establishes module ownership before host loading; direct, nested, atom-targeted, macro-generated, runtime-generated, and spawned-process-generated ordinary Elixir modules are supported when conflict-free. Cache hits enforce the same metadata, completeness, resource-limit, and ownership checks as fresh compilation. This protects host validation but does not sandbox trusted extension filesystem or network authority.

The validated artifact inventory, not an AST prediction or one entry module, owns the source's modules. A source can emit helper modules through ordinary Elixir compilation as long as every validated BEAM name matches its artifact and no module belongs to Minga, an OTP application, or another extension.

Stopping, disabling, lazily starting, or restarting an extension in the current session uses only the artifact admitted for that source when the VM generation began. Source edits, user-module edits under `~/.config/minga/modules`, and Git updates require a fresh Minga OS process. Config reload reports a restart requirement instead of purging, recompiling, or replacing resident code. The updater stages accepted Git source for the next process and rolls the checkout back on a staging failure without disturbing the active runtime.

## Lifecycle and child restart

Every declaration has one stable `Minga.Extension.Instance` mailbox. Public start and stop APIs, lazy triggers, failed starts, runtime exits, and config reload all send lifecycle intent there. The PID in extension listings is only a projection of the current runtime child and is never an authority extension code should retain.

The Instance validates options and runs `init/1` before it starts the child returned by `child_spec/1`. After the child is alive, it registers commands, keybindings, editor callbacks, and callback admission before publishing `:running`. If setup fails, it follows the same stop order as a normal disable and preserves the start diagnostic, wrapping it only when cleanup also fails.

The top-level `restart` value returned by `child_spec/1` is interpreted by the Instance. Minga starts the actual runtime child as `:temporary` under the extension's local runtime supervisor, so OTP does not race the lifecycle authority. `:permanent` restarts after every terminal exit, `:transient` restarts after abnormal exits, and `:temporary` never restarts. If your child is itself a supervisor, that supervisor still owns its internal children normally.

```elixir
def child_spec(config) do
  Supervisor.child_spec({MyExtension.Supervisor, config}, restart: :transient)
end
```

A runtime disable leaves modules resident. The Instance first closes new callback admission, waits for source leases to drain, and asks the Editor to cancel source-owned effects. It then runs source-filtered `:source_unload` callbacks, terminates the runtime child, removes source-owned contributions once, publishes `:stopped`, and acknowledges the caller. Editor finalization is asynchronous, so an unload callback must not synchronously call back into extension lifecycle APIs.

## Runtime callbacks and source-owned work

Use `editor_event_handler/3` for the retained callback families: `:buffer_saved`, `:editor_action`, and `:source_unload`. Buffer-save handlers run as an ordered fan-out. Editor actions stop at the first `{:handled, state}` and continue only after `:not_matched`. Source-unload handlers run only for the extension being disabled.

Dynamic extension callbacks cross `Minga.Extension.CallbackInvoker`. Exceptions, throws, exits, unavailable modules, and invalid return values become explicit callback failures and are reported without turning into a second callback protocol. Core callbacks execute directly and retain normal OTP crash behavior. Extension commands and editor handlers should return the documented state shape rather than rescuing framework failures themselves.

Slow picker, Git, and similar work must be represented as a typed `MingaEditor.Effect` request. `MingaEditor.EffectScheduler` owns worker supervision, resource ordering, cancellation, and result application. Tag requests with the extension source so disable can cancel them before presentation and callback registrations are removed. Do not spawn an untracked task and send a custom result message to the Editor.

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
