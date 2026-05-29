import Config

# Suppress routine info-level startup logs on the console.
# Subsystem-specific debug logging still goes to *Messages* when enabled.
config :logger, level: :warning

# Development checkouts load bundled extensions directly from the source tree when priv copies are not present yet.
config :minga, allow_source_extension_fallback: true

# Always recompile extensions in dev. The compile cache keys on extension source
# + toolchain + minga version, so editing minga's own modules (which extensions
# compile against) would otherwise serve a stale extension beam until the
# extension's own source changes. Fresh compiles keep hot-reload correct; the
# cache stays on for prod releases where boot speed matters.
config :minga, extension_compile_cache: false
