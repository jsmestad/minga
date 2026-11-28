# Spike for #4386: a PTY for output, `/dev/null` for input

Never merges. Results are on the issue.

- `runpty.c`: the helper. `cc -O2 -o runpty runpty.c`
- `probe.c`: deterministic probes of what a command sees. `cc -O2 -o probe probe.c`
- `matrix.sh`: every probe across controlling terminal (yes, no) and output mode (read-write, write-only).
- `fixtures.sh DIR`: throwaway projects for the real-command runs.
- `realcmds.sh FIXTURES OUT`: real commands under two configurations.
- `watchcheck.sh NODE_PROJECT`: watch-mode runners rerun without keyboard input.
- `agentdiff.sh FIXTURES`: pipe output against stripped PTY output.
- `linux.sh`, `linux2.sh`: the Linux passes, run inside containers.
