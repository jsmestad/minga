import Config

# Suppress routine info-level startup logs on the console.
# Subsystem-specific debug logging still goes to *Messages* when enabled.
config :logger, level: :warning

# Development checkouts load bundled extensions directly from the source tree when priv copies are not present yet.
config :minga, allow_source_extension_fallback: true
