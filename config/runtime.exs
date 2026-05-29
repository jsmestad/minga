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

# The default Erlang logger handler writes to :standard_io (stdout). For
# both of these modes, stdout is NOT a safe place for log text, so we redirect
# the default handler to the Minga log file from the very start of boot:
#
#   - connected mode: stdout is the {:packet, 4} binary protocol pipe to the
#     Swift GUI. Unframed log text corrupts the stream (unknownOpcode errors).
#   - standalone TUI: stdout is the user's terminal. Boot logs (EventRecorder,
#     extensions, watchdog, ...) would print over the editor UI.
#
# This matches what LoggerHandler.install/0 does later during Editor.init, but
# covers the startup window before the Editor is running. Headless and `mix`
# invocations are intentionally excluded so they keep stdout/stderr logging.
standalone_tui? =
  System.get_env("__BURRITO") != nil and
    "--headless" not in Enum.map(:init.get_plain_arguments(), &to_string/1)

if port_mode == :connected or standalone_tui? do
  log_dir = Path.expand("~/.local/share/minga")
  File.mkdir_p!(log_dir)
  log_path = Path.join(log_dir, "minga.log")
  config :logger, :default_handler, config: [type: {:file, String.to_charlist(log_path)}]
end

# Connected mode means the GUI app spawned us. Start the editor with
# the GUI backend so the supervision tree boots Port.Manager, Editor,
# and the parser. Without this, the BEAM process sits idle and the
# Swift frontend sees only its default (empty) SwiftUI state.
if port_mode == :connected do
  config :minga, start_editor: true, backend: :gui
end
