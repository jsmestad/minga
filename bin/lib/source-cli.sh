# Detect commands that don't use the renderer before starting a native build.
terminal_only() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h|--version|-v|sessions|detach|kill-session|login|--headless)
        return 0 ;;
      --config|--debug-log|-D|--name|--sname|--cookie-file|--host|--port)
        [ "$#" -ge 2 ] || return 1
        shift 2 ;;
      --editor|--minimal|--safe|-Q|--no-context)
        shift ;;
      *) return 1 ;;
    esac
  done
  return 1
}
