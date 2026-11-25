# Mix finds the project in the directory it runs in, so the launcher moves to the source tree, and the editor
# stays there. The caller's directory travels in MINGA_LAUNCH_DIR as data: `minga` typed inside a project opens
# that project, and a relative file argument is resolved against the directory the caller typed it in.
enter_source_tree() {
  MINGA_LAUNCH_DIR="$(pwd -P)"
  export MINGA_LAUNCH_DIR
  cd "$PROJECT_DIR"
}

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
