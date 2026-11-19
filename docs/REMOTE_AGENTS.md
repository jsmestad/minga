# Remote Agents

Remote agents let a headless Minga process keep working after every editor window disconnects. The model is closer to tmux than SSH foreground jobs: the server owns provider credentials, configuration, durable session state, and running agent work. Clients attach, catch up, drive or observe the session, and detach without stopping the work.

## Run the headless daemon

Start the daemon with `minga --headless`. In headless mode Minga starts the runtime, distribution, services, and agent supervisor without opening a frontend port.

### Linux systemd user service

Copy `rel/systemd/minga-headless.service` to `~/.config/systemd/user/minga-headless.service`, edit `ExecStart`, `WorkingDirectory`, `RELEASE_COOKIE`, and provider environment variables, then run:

```sh
systemctl --user daemon-reload
systemctl --user enable --now minga-headless.service
loginctl enable-linger "$USER"
```

`loginctl enable-linger` is what lets the user service keep running across logout and login. Without linger, most Linux systems stop user services when the last login session exits.

### macOS launchd agent

Copy `rel/launchd/com.minga.headless.plist` to `~/Library/LaunchAgents/com.minga.headless.plist`, edit the absolute binary path, working directory, cookie, and provider environment variables, then run:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.minga.headless.plist
launchctl enable gui/$(id -u)/com.minga.headless
launchctl kickstart -k gui/$(id -u)/com.minga.headless
```

Use `launchctl bootout gui/$(id -u)/com.minga.headless` to stop the agent.

## Network and trust boundary

Remote control uses Erlang distribution. Set a long random `RELEASE_COOKIE` (at least 32 random bytes) on the daemon and every trusted client that needs to connect. The release launcher consumes this value before the VM boots; `MINGA_COOKIE` remains a supported CLI-facing alias only when a wrapper maps it to `RELEASE_COOKIE` before startup. Treat the cookie like a password: any node with the cookie can reach the trusted broker API.

The installed TUI launcher reads `--cookie-file` and exports `RELEASE_COOKIE` before the VM starts. The file takes precedence over inherited cookie variables.

The attach command uses SSH as the bootstrap channel. It asks the remote host to start the user daemon with `systemctl --user start minga-headless.service`, falling back to the launchd agent command on macOS, then connects to the conventional distributed node `minga_server@host`. If bootstrap fails, the CLI prints the SSH command failure so you can install the service file, enable linger, or fix the cookie/node setup.

Bind the server on a private network such as Tailscale or a locked-down LAN. Do not expose Erlang distribution ports directly to the public internet.

Provider credentials live on the server. For a quick local setup you can put keys in the systemd `Environment=` lines or the launchd `EnvironmentVariables` dictionary, but prefer a `0600` systemd `EnvironmentFile`, systemd credentials, macOS Keychain, or another local secret manager on shared machines. Attaching clients do not push provider credentials or config into the daemon.

## Sign in on a headless server

Use `minga login --manual` on the server when OAuth needs a browser but the daemon host has none. Minga prints an authorize URL, waits for one pasted value, and writes the resulting tokens to the server's `oauth.json`. Open the URL on your laptop, approve the request, then paste either the full failed redirect URL, the bare authorization code, or the `code#state` value back into the terminal.

From an attached GUI, use `/login --manual`. The server creates the PKCE verifier and returns only the authorize URL and flow ref through `MingaAgent.RemoteAPI`. After approval, paste the redirect back with `/login --complete <ref> <redirect-url-or-code>`. The PKCE verifier never leaves the server.

## Attach, list, detach, and end

Use `minga attach ssh://devbox/work/app` to connect to the agent session anchored to `/work/app` on `devbox`. The path is a server-side checkout or worktree. Minga does not copy source code to the client.

Use `minga sessions ssh://devbox` to print live sessions without launching the editor. The output includes the session id, status, working directory, and recent prompt text when available.

Use `minga detach` to disconnect the local frontend. Detaching only removes the client subscriber. It records a `user_disconnected` event in the durable event log and leaves the agent turn running. If the laptop closes while a tool is running, the server keeps the session alive and the next attach catches up from the client's last seen event id.

Use `minga kill-session ssh://devbox/work/app` to end the session for that server-side working directory. Under the hood this calls the brokered `MingaAgent.RemoteAPI.stop_session/2`, which validates the session token and stops that session on the server.

## Answer a remote Agent question

If the Agent needs a decision before it can continue, the attached editor offers **Answer question**. A disconnect does not answer it. Reattach as the driver to inspect the same question and choose, type, or cancel. If the server restarts before it saves an answer, the recovered conversation records the interruption instead of inventing an answer or asking again automatically.

A broker client that can present questions sets `questions?: true` when it calls `MingaAgent.RemoteAPI.attach/4`. The Session sends the private question receipt directly to the attached driver PID as `{:agent_question_attachment, session_pid, receipt}`. Do not log or persist it. Detach invalidates that receipt, even if the same process reattaches.

A fresh conversation advertises `ask_user` only for a capable driver. A retained conversation keeps its original tool declaration when the driver changes. Without a capable driver, a new `ask_user` call returns an explicit refusal instead of waiting. Inspect the exact pending question with `MingaAgent.RemoteAPI.pending_question(session_id, token)`.

For example, a driver can choose the second label in the question it displayed:

```elixir
{:ok, {target, question}} = MingaAgent.RemoteAPI.pending_question(session_id, token)
# After the driver selects the second item in question.choices:
MingaAgent.RemoteAPI.respond_to_question(session_id, token, {driver_pid, receipt}, target, {:choice, 1})
```

Choice indexes are zero based. Send `{:text, answer}` for a typed answer or `:cancel` to send no answer. The session token and the private receipt for the current driver are both required. A viewer, stale receipt, or stale target cannot change the turn. No response grants tool permission.

## Idle reclamation policy

Detached sessions are reclaimed by `:agent_session_idle_timeout_ms`. The default is four hours (`14_400_000` ms). Set it to `0` to disable idle reclamation on hosts where sessions should remain until explicitly ended.

The reclaimer only stops sessions with no attached clients and no active agent work. A session that is thinking, executing a tool, or waiting on an approval or question is never reclaimed out from under the user. When the active turn returns to idle and there are still no subscribers, the timeout starts again.

Saved session files and the durable event log are still subject to their own retention settings, such as `:agent_session_retention_days` and `:event_retention_days`.

## Recover complete shell output

A long test log must remain readable after its preview leaves model context.
Agent shell tools retain stdout and stderr as exact bytes in the session record's artifact store; the model-visible preview stays within 51,200 bytes.
That preview limit is not a capture limit.
Trailing whitespace belongs to the capture, while an exit-status annotation belongs only to the preview.
Capture reads on demand, so slow storage blocks the producer instead of accumulating an unbounded output queue in the BEAM.

In the Agent workspace, expand the native tool card and choose **Read retained output**, or select the same action on a Go terminal tool card. `Ctrl+Alt+O` opens the latest tool result in the terminal. For example, reopen a session after changing a log file, then copy a range or read the complete original capture before copying it. Minga reads the stored bytes, not the changed file. Copy actions identify partial captures and label binary data as Base64. For captures above 16 MiB, copy ranges rather than the whole capture at once.

Use `fetch_output` with the reference from the shell result, then advance the requested byte range until every retained byte has been read.
For example, after reading the first 51,200 bytes, build the next request from the decoded result without reconstructing its reference:

```elixir
args = %{
  "reference" => shell_result["reference"],
  "unit" => "bytes",
  "start" => 51_200,
  "count" => 51_200
}
```

Each fetch stays bounded.
Binary data and byte ranges that split a UTF-8 character use an explicitly labelled base64 view.
Compaction and application restart do not require rerunning the command: load the saved session and use its restored output reference.
Configured artifact quotas and explicit retention cleanup still apply.
If a quota or interruption stops capture, the result reports an incomplete capture and retains the admitted prefix; it never claims that prefix is the complete command output.
If durable storage is unavailable before execution, the tool fails without starting the command.
