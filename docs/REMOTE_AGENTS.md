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

Bind the server on a private network such as Tailscale or a locked-down LAN. Do not expose Erlang distribution ports directly to the public internet.

Provider credentials live on the server. Put keys in the systemd `Environment=` lines, the launchd `EnvironmentVariables` dictionary, or the server user's normal secret-management setup. Attaching clients do not push provider credentials or config into the daemon.

## Detach, reconnect, and end

Detaching only removes the client subscriber. It records a `user_disconnected` event in the durable event log and leaves the agent turn running. If the laptop closes while a tool is running, the server keeps the session alive and the next attach catches up from the client's last seen event id.

Use the brokered remote API to end a session deliberately. `MingaAgent.RemoteAPI.stop_session/2` validates the session token and stops that session on the server. The CLI attach UX will expose this as a user-facing command in the attach slice.

## Idle reclamation policy

Detached sessions are reclaimed by `:agent_session_idle_timeout_ms`. The default is four hours (`14_400_000` ms). Set it to `0` to disable idle reclamation on hosts where sessions should remain until explicitly ended.

The reclaimer only stops sessions with no attached clients and no active agent work. A session that is thinking, executing a tool, or waiting on a pending approval is never reclaimed out from under the user. When the active turn returns to idle and there are still no subscribers, the timeout starts again.

Saved session files and the durable event log are still subject to their own retention settings, such as `:agent_session_retention_days` and `:event_retention_days`.
