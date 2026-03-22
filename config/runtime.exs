import Config

# Port mode: how the BEAM connects to the GUI frontend.
#
# - "connected" — the GUI process spawned us as a child. Our stdin/stdout
#   are already piped to the GUI. Port.Manager opens {fd, 0, 1} instead
#   of spawning a new child process. Set by the Swift app via the
#   MINGA_PORT_MODE env var when launching the embedded BEAM release.
#
# - "spawn" (default) — we're the parent. Port.Manager spawns the GUI
#   binary as a child process via Port.open({:spawn_executable, ...}).
port_mode =
  case System.get_env("MINGA_PORT_MODE") do
    "connected" -> :connected
    _ -> :spawn
  end

config :minga, port_mode: port_mode
