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

# Connected mode means the GUI app spawned us. Start the editor with
# the GUI backend so the supervision tree boots Port.Manager, Editor,
# and the parser. Without this, the BEAM process sits idle and the
# Swift frontend sees only its default (empty) SwiftUI state.
#
# The default Erlang logger handler writes to :standard_io (stdout).
# In connected mode, stdout is the binary protocol pipe to the Swift
# frontend. Unframed log text would corrupt the {:packet, 4} protocol
# stream, causing unknownOpcode decode errors on the Swift side.
#
# Redirect the default handler to the Minga log file. This matches
# what LoggerHandler.install() does later during Editor.init, but
# covers the startup window before the Editor is running.
if port_mode == :connected do
  config :minga, start_editor: true, backend: :gui

  log_dir = Path.expand("~/.local/share/minga")
  File.mkdir_p!(log_dir)
  log_path = Path.join(log_dir, "minga.log")
  config :logger, :default_handler, config: [type: {:file, String.to_charlist(log_path)}]
end
