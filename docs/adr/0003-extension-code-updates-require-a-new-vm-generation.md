# ADR-0003: Extension code updates require a new VM generation

**Status:** Accepted (2026-07-14). Decision ticket: #2926. Implementation epic: #2925.

## Decision

Minga separates an extension's runtime lifecycle from activation of its code. An extension can be stopped, disabled, restarted after a crash, or started lazily inside the current Minga session, but every start in that session uses code admitted for that extension when the BEAM VM generation began. Installing, updating, or editing extension code takes effect only after Minga starts a fresh BEAM OS process.

Stopping and starting the `:minga` OTP application inside the same VM is not a code-generation boundary. It leaves loaded modules and old-code generations in the same code server, so it does not activate changed extension code under this contract.

Runtime disable does not purge modules. It closes new work admission, cancels or settles source-owned work, stops the extension process tree, removes source-owned contributions, and removes Editor-owned presentation state. Loaded modules remain resident until the VM exits.

## Why this boundary exists

Minga extensions are trusted Elixir code running inside the editor VM. They can contain multiple modules, supervision trees, closures, protocols, dependency applications, and private state. The BEAM can keep current and old versions of one module, but it does not provide an atomic upgrade boundary for an arbitrary extension and all of those resources.

Live replacement would therefore require Minga to prove that every executing callback, queued closure, worker, contribution, dependency, and process has crossed the same version boundary. The current code-lease and purge machinery approximates that proof manually. A missed path can execute code while another path deletes or purges it.

A fresh VM gives the whole extension graph one unambiguous generation. Minga keeps responsive runtime disable and crash recovery without pretending it can safely replace arbitrary third-party code in place.

## User workflows

### Configuration reload

`SPC h r` reloads ordinary configuration without promising to activate changed extension modules. Changes to options, keybindings, hooks, and other config-owned declarations may apply in the current session. Adding an extension, changing its source or code, or re-enabling code that was not admitted for this VM reports that a restart is required.

An unchanged extension may be disabled and started again from its admitted artifact. Reload never recompiles current path or Git source into the running VM after the generation is sealed.

### Runtime enable and disable

Disable takes effect in the current session. New commands, callbacks, registrations, and effects from that source are rejected once shutdown begins. Contributions and Editor presentation disappear without waiting for code purge.

A later start in the same session is allowed only when it uses the exact artifact admitted for that extension in the current VM generation. Newly installed or changed artifacts remain pending until restart.

### Installation and update

Installing an extension prepares its source or artifact and reports that Minga must restart before the extension can run. Git updates fetch and stage the accepted revision without recompiling or replacing the active extension in the current VM. Hex constraint or dependency changes follow the same rule.

If staging fails, the current running generation remains unchanged. Recovery means fixing or rolling back the staged source and starting a new Minga process. There is no in-VM compile rollback because active code was never replaced.

### Extension development

Path-extension edits do not activate through config reload. Restart Minga to compile and admit the changed source into a new VM generation. Development tooling may make that restart fast, but it must not disguise same-VM code replacement as a restart.

### Crash recovery

An extension's stable identity is its declared source identity, not its current runtime child PID. Internal supervisor restarts may replace child PIDs while the extension remains available, provided they use the artifact admitted for the current VM generation. A terminal failure follows the same source-owned cleanup path as disable and remains observable through lifecycle status and telemetry.

## Lifecycle authority and ordering

One per-extension lifecycle authority serializes start, lazy activation, disable, stop, crash, and restart requests. The extension registry is a readable projection of that authority's state, not a second decision maker. The current runtime PID is replaceable observed state.

Disable follows this ordering:

1. Transition the extension identity to a closing phase and reject new source-owned work and registrations.
2. Make dispatch-visible contributions unavailable so no new callback begins.
3. Cancel queued source-owned effects and request cancellation of running effects through their owning scheduler. Work with a declared finish policy may settle before the bounded shutdown deadline.
4. Stop the extension runtime subtree.
5. Run every source-owned cleanup family, preserving later cleanup even when an earlier family reports an error.
6. Ask the Editor asynchronously to remove live and stashed extension presentation state through its behavioral owners.
7. Publish the terminal lifecycle projection. Late outcomes carry generation and semantic correlation that prevents them from restoring state.

The Editor does not synchronously wait for an extension authority that is waiting for Editor finalization. External workers return data, and Editor transitions remain serialized in the Editor mailbox as required by ADR-0002.

A cleanup error does not reopen admission or roll the extension back to running. The lifecycle projection reports the failure and permits a later same-artifact retry only after cleanup has reached a safe terminal state.

## Source compatibility

The contract applies uniformly to bundled, module, path, Git, and Hex/application extensions.

- Bundled and module extensions start from code admitted at boot.
- Path and Git extensions may compile into a boot artifact cache, but current-session starts use the captured artifact rather than recompiling the live checkout.
- Git updates may change the cached checkout for the next VM without changing the running generation.
- Hex dependency and application changes require a fresh VM. Shared dependency applications are not stopped or replaced as part of one extension's runtime disable.
- Extension-owned processes must live under the extension runtime subtree or run as source-attributed work under a lifecycle-aware shared scheduler. Arbitrary unlinked processes are outside the disable guarantee.

Existing callback, DSL, and `child_spec/1` contracts remain compatible. The intentional compatibility change is that same-VM activation of changed code is no longer promised.

## BEAM evidence

The decision does not depend on force purge being unsafe in theory. OTP 29 demonstrates the narrower fact that non-destructive purge is process-sensitive and retryable, not an atomic extension upgrade mechanism.

Run this experiment in a disposable directory with Elixir 1.20 and OTP 29. It loads version 1 of an Erlang module, keeps one process executing old code, loads version 2, and exercises delete and soft purge:

```elixir
root = Path.join(System.tmp_dir!(), "minga-adr-0003-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)

compile = fn version ->
  source = "-module(adr0003_probe). -export([hold/1, fresh/0]). hold(Parent) -> Parent ! {entered, #{version}}, receive release -> {returned, #{version}} end. fresh() -> {fresh, #{version}}."
  erl = Path.join(root, "adr0003_probe.erl")
  File.write!(erl, source)
  {:ok, :adr0003_probe, beam} = :compile.file(String.to_charlist(erl), [:binary])
  beam
end

v1 = compile.(1)
v2 = compile.(2)
{:module, :adr0003_probe} = :code.load_binary(:adr0003_probe, ~c"v1", v1)
parent = self()
old = spawn(fn -> send(parent, apply(:adr0003_probe, :hold, [parent])) end)
receive do {:entered, 1} -> :ok end
{:module, :adr0003_probe} = :code.load_binary(:adr0003_probe, ~c"v2", v2)
IO.inspect(:code.delete(:adr0003_probe), label: "delete while old code executes")
IO.inspect(:code.soft_purge(:adr0003_probe), label: "soft purge while old code executes")
IO.inspect(apply(:adr0003_probe, :fresh, []), label: "current call")
send(old, :release)
receive do result -> IO.inspect(result, label: "old call") end
IO.inspect(:code.soft_purge(:adr0003_probe), label: "soft purge retry")
```

Observed output:

```text
delete while old code executes: false
soft purge while old code executes: false
current call: {:fresh, 2}
old call: {:returned, 1}
soft purge retry: true
```

The old process completes without being killed, and a later soft purge succeeds. This makes soft purge suitable as a VM code-server authority when a system deliberately supports live upgrades. It does not make a set of extension modules, processes, registrations, and dependencies upgrade atomically.

## Mechanisms this decision makes removable

The #2925 migration can remove runtime `:code.delete/1`, `:code.purge/1`, and `:code.soft_purge/1` paths for extensions; purge-specific admission gates and drain tokens; same-VM updater recompilation and compile rollback; the dormant development reload watcher; lazy-load recompilation of current disk contents; and child-PID reconciliation used as extension identity.

The compile cache remains useful for preparing boot artifacts. Source-owned contribution cleanup, Editor presentation cleanup, scheduler cancellation, lifecycle telemetry, crash supervision, manifest and option validation, and stable registry projection remain necessary because they serve runtime disable and failure recovery rather than code replacement.

## Alternatives rejected

### Live replacement with soft purge

The strongest case for live replacement is development speed and a seamless update experience. The BEAM's two-code-version support allows old calls to finish while new calls enter current code, and `:code.soft_purge/1` can be retried without killing an old-code process.

Minga rejects this option for arbitrary in-process extensions because correct replacement would also need atomic multi-module admission, complete work tracking, state migration, dependency and application ownership, contribution swaps, and rollback. Soft purge solves only the code-server portion. Minga can revisit live replacement only with a restricted extension API or an isolated extension VM/process boundary.

### Current force-purge model

Forceful purge can terminate processes executing old code and depends on every dynamic call path participating in manual lease coverage. It is incompatible with Minga's failure-isolation goal and is removed as the migration replaces its safety responsibilities.

## Consequences

Extension authors trade same-VM code activation for a lifecycle contract that is easier to understand and recover. Runtime disable remains immediate at the authority boundary, crash recovery remains supervised, and active code cannot be partially replaced by an update or config reload.

Users must restart Minga after installing an extension or changing extension code, source, or dependencies. Minga should make pending-restart status explicit instead of reporting a successful reload that did not activate the new artifact.
