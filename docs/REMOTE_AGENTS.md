# Remote Agents

Remote agents let a headless Minga process keep working after every editor window disconnects. The model is closer to tmux than SSH foreground jobs: the server owns provider credentials, configuration, durable session state, and running agent work. Clients attach, catch up, drive or observe the session, and detach without stopping the work.

## Run the headless daemon

Start the daemon with `minga --headless`. In headless mode Minga starts the runtime, distribution, services, and agent supervisor without opening a frontend port.

### Linux systemd user service

Copy `rel/systemd/minga-headless.service` to `~/.config/systemd/user/minga-headless.service`, edit `ExecStart`, `WorkingDirectory`, `MINGA_COOKIE`, and provider environment variables, then run:

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

Remote control uses Erlang distribution. Set a long random `MINGA_COOKIE` on the daemon and every trusted client that needs to connect. Treat the cookie like a password: any node with the cookie can reach the trusted broker API.

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

## Idle reclamation policy

Detached sessions are reclaimed by `:agent_session_idle_timeout_ms`. The default is four hours (`14_400_000` ms). Set it to `0` to disable idle reclamation on hosts where sessions should remain until explicitly ended.

The reclaimer only stops sessions with no attached clients and no active agent work. A session that is thinking, executing a tool, or waiting on a pending approval is never reclaimed out from under the user. When the active turn returns to idle and there are still no subscribers, the timeout starts again.

Saved session files and the durable event log are still subject to their own retention settings, such as `:agent_session_retention_days` and `:event_retention_days`.
