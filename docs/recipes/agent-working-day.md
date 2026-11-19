# Verify a working day in the Agent workspace

Use this scenario to find failures between setup, editing, running an Agent turn, recovering work, and reviewing the result. Run it on the actual macOS app and the production Go terminal frontend. A screenshot of a fixture, a successful command in a separate shell, or an idle Agent does not prove the workspace flow passed.

## Start with a known project

You need a built Minga development checkout with both frontends, Git, Python 3, a Python language server, and an approved test provider account. Follow [live workspace capture](capture-agent-workspace.md) for input and evidence. Use a dedicated test OS account or VM with no developer credentials. Do not copy credentials or capture secret entry.

Run this setup in a separate terminal. It creates a disposable repository and never modifies an existing one. Keep this terminal for independent verification at the end.

```sh
fixture_git() {
  env -i PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git "$@"
}
scenario=$(mktemp -d "${TMPDIR:-/tmp}/minga-working-day.XXXXXX") || exit 1
cd "$scenario" || exit 1
(
set -e
fixture_git init --quiet --template=
cat > greeting.py <<'PY'
def greet(name):
    return f"Hello, {name}!"
PY
cat > test_greeting.py <<'PY'
import unittest

from greeting import greet


class GreetingTest(unittest.TestCase):
    def test_named_guest(self):
        self.assertEqual(greet("Ada"), "Hello, Ada!")

    def test_blank_name(self):
        self.assertEqual(greet(""), "Hello, guest!")
PY
printf 'Temporary implementation note\n' > legacy-note.txt
printf 'Unrelated operator notes\n' > operator-notes.txt
fixture_git add greeting.py test_greeting.py legacy-note.txt
fixture_git -c user.name='Minga Scenario' -c user.email='scenario@example.invalid' \
  -c core.hooksPath=/dev/null -c commit.gpgsign=false commit --quiet -m 'Working-day fixture v1'
)
test "$?" -eq 0 || exit 1
base_commit=$(fixture_git rev-parse --verify HEAD) || exit 1
printf 'Base commit: %s\nOpen this file in Minga: %s/greeting.py\n' "$base_commit" "$scenario"
python3 -B -m unittest -v
```

The last command must report one passing test and one failure, `test_blank_name`. Record the base commit, build commit, and Python version. Do not proceed with a different initial result.

## Start an isolated frontend

In a second terminal, set `checkout` to the absolute path of the built checkout, `project` to the disposable repository path printed above, and `frontend` to `gui` on macOS or `tui` for Go. Put the pinned tool binaries on `PATH`. In the same terminal, repeat only the `launch_workspace` call when testing restart or reconnect. Create a fresh profile for a new run.

```sh
profile=$(mktemp -d "${TMPDIR:-/tmp}/minga-working-profile.XXXXXX") || exit 1
mkdir -p "$profile"/home "$profile"/config "$profile"/data "$profile"/cache "$profile"/state || exit 1
launch_workspace() (
  case "$frontend" in
    gui) set -- +gui ;;
    tui) set -- ;;
    *) printf 'Set frontend to gui or tui\n' >&2; exit 1 ;;
  esac
  cd "$checkout" || exit 1
  env -i PATH="$PATH" TERM="${TERM:-xterm-256color}" LANG="${LANG:-C.UTF-8}" \
    HOME="$profile/home" XDG_CONFIG_HOME="$profile/config" XDG_DATA_HOME="$profile/data" \
    XDG_CACHE_HOME="$profile/cache" XDG_STATE_HOME="$profile/state" \
    MIX_ARCHIVES="${MIX_ARCHIVES:-$HOME/.mix/archives}" MINGA_SKIP_NATIVE_LAUNCH_BUILD=1 \
    bin/minga "$@" "$project/greeting.py"
)
launch_workspace
```

Before signing in, open the provider setup in the workspace and confirm there is no connected provider. If a route is already connected, stop and correct the isolation. Install or configure the diagnostic language server in this test environment without restoring the developer config.

## Follow the workspace flow

1. **Connect and start.** Open `greeting.py`. Use the visible setup and model controls to connect an approved test provider. Record every action and explanation in the first five minutes, including empty, loading, and error states. Use a fresh session for the task. In an editor buffer, make a temporary unsaved edit referencing an undefined name. Wait for the language server to publish the diagnostic. Attach both the unsaved selection and the diagnostic, inspect both snapshots, then undo the temporary edit before dispatch so it does not become part of the task. Ask the Agent to make empty and whitespace-only names greet `guest`, preserve ordinary names, add a whitespace regression test and a `README.md` explaining the behavior, and remove `legacy-note.txt`. Tell it not to modify `operator-notes.txt`, stage, or commit. Have it request permission separately for the test command and for any service start.
2. **Work while the Agent runs.** Read earlier output and keep typing a separate unsent draft. Confirm Agent edits do not move the selection, reading position, or keyboard focus. Steer the active turn, queue two follow-ups, edit one, and remove the other before consumption. Retain the original and current identities where evidence tooling exposes them. Verify a late or repeated action does not duplicate input or affect another session. Use two sessions when testing this boundary.
3. **Exercise decisions and jobs.** Answer a question, then grant and deny separate permissions. Check default approval focus, refocus the composer, and activate the approval control without losing the draft. With one approval retired and another pending, exercise the captured old control through the existing stale-action evidence path. Check that the new approval remains pending. Run `python3 -B -m unittest -v` through Minga before and after the change. Start a managed verification service with `python3 -B -u -m http.server 0 --bind 127.0.0.1 --directory .` in the disposable project. Observe readiness and output, stop that service, and inspect the terminal result. Do not serve private files or bind beyond loopback.
4. **Interrupt and recover.** Record one provider failure, two compactions, a supported model transition, and a full restart. Reopen by the original session identity. Inspect tasks, pending decisions, retained output, changes, and any accepted but unconsumed queue items. Confirm reopening does not dispatch queued input or replay unknown effects. Exercise explicit Continue and Discard on separate recovered items and verify the dispositions on a second reopen. Include draft persistence refusal, interrupted output retrieval, a stale review action, notification permission denied, and service interruption with an unknown outcome. Use the existing recovery evidence path for deterministic faults and label those runs separately from live-provider evidence.
5. **Review the result.** In the workspace, distinguish proposed, applied, and reviewed changes. Inspect file creation, modification, deletion, and a conflict in a separate run. Keep unrelated edits separate. Retrieve an older message and the complete retained output for a command. Inspect how focus returns after closing review and history. Then run the independent checks below. Record a mismatch as a failure even if the Agent reported success.

If a control or evidence route cannot perform a step, record the exact missing behavior and link its owner. Do not use a hidden binding, runtime call, provider substitute, or acceptance shortcut to claim a pass.

## Check the result outside Minga

Run these commands from the same disposable repository:

```sh
(
set -e
cd "$scenario" || exit 1
test "$(fixture_git rev-parse --verify HEAD)" = "$base_commit" || exit 1
fixture_git diff --cached --exit-code
python3 -B -m unittest -v
fixture_git diff --check HEAD
fixture_git diff --name-status HEAD
fixture_git status --short
printf 'Unrelated operator notes\n' | cmp - operator-notes.txt
)
```

The three named, empty, and whitespace tests must pass. Review `fixture_git diff HEAD` and the new `README.md`. The only changes are modifications to `greeting.py` and `test_greeting.py`, deletion of `legacy-note.txt`, and the new `README.md`. `operator-notes.txt` is still untracked and byte-for-byte unchanged. The Agent must not stage or commit. `fixture_git diff --check HEAD` does not check the untracked README, so inspect it separately.

## Keep a receipt for every run

Record date, fixture version, base and build commits, OS/hardware, frontend and emulator, viewport, theme/font, cold/warm state, model/route/auth mode without credentials, action, expected and observed result, intervention, and sanitized artifact paths. Mark each result pass, fail, blocked, or not applicable with a reason. Keep the whole native workspace capture, plus raw Go PTY output and its rendered view. Record failures alongside successful attempts.

Repeat at normal and narrow widths with keyboard and pointer. On macOS also verify native accessibility. Cover supported appearances, Unicode and IME, long paths and output, selection and copy, disabled controls, focus return, reduced motion, and background attention. Record hierarchy, spacing, contrast, and any truncated content that cannot be inspected.

Use the same optimized build and paired inputs for baseline comparisons: empty, 100 and 10,000 retained messages, 100 changed files, 1 MiB retained output, the largest admitted relevant payload, and concurrent editing and streaming. Capture p50/p95 from action to visible result, separated request/render/transport timing, message and byte counts, peak retained resources, and surviving child processes. Report the median and range of real task time and cost.

This recipe defines the baseline, not a release verdict. [#3454](https://github.com/jsmestad/minga/issues/3454) requires at least three fresh-state real tasks plus one 60-minute sustained session per frontend, linked failures, and all dependency evidence. Do not count isolated component passes or simulated provider results toward those runs.
