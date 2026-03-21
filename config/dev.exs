import Config

# Suppress routine info-level startup logs on the console.
# Subsystem-specific debug logging still goes to *Messages* when enabled.
config :logger, level: :warning
