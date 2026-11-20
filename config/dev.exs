import Config

# Suppress routine info-level startup logs on the console.
# Subsystem-specific debug logging still goes to *Messages* when enabled.
config :logger, level: :warning

# Development checkouts load bundled extensions directly from the source tree when priv copies are not present yet.
config :minga, allow_source_extension_fallback: true

# Source launches must not write to the installed editor's project switcher.
config :minga, known_projects_filename: "known-projects-dev"

# Always compile extensions during development process startup. The compile cache
# keys on extension source + toolchain + minga version, so editing Minga modules
# that extensions compile against could otherwise serve stale boot artifacts.
# Extension code changes still require a fresh BEAM OS process; production keeps
# the cache enabled for boot speed.
config :minga, extension_compile_cache: false
