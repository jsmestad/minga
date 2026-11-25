import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import {
  CAPTION_IDS,
  STEP_IDS,
  createVetoState,
  currentStep,
  editsBlockedCommand,
  evaluateHook,
  hookPayload,
  newlyDone,
  presetFillsField,
  reduceVeto,
  type CaptionId,
  type StepId,
  type VetoEvent,
  type VetoRule,
  type VetoState,
} from "../src/veto_state.ts";
import { missing, readPageLab } from "./support/page_copy.ts";

const PAGE = "learn/remote.html";
const lab = readPageLab(PAGE, "data-remote-lab");

/** The visible text of a piece of page markup. Tags are removed until none is left, so a tag that only appears once another is gone cannot survive. */
function plain(html: string): string {
  let text = html;
  let before: string;
  do {
    before = text;
    text = text.replace(/<[^>]*>/g, "");
  } while (text !== before);
  return text
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&amp;", "&");
}

/** The inner HTML of the first element in the lab that carries `attr`, found by its closing tag. The elements read this way hold no nested tag of the same name. */
function inner(html: string, attr: string, tag: string): string[] {
  return Array.from(html.matchAll(new RegExp(`<${tag}\\b[^>]*\\s${attr}(?:="[^"]*")?[^>]*>([\\s\\S]*?)</${tag}>`, "g")), (m) => m[1]!);
}

/** The hook script exactly as a reader copies it from the page. */
const SCRIPT = `${plain(inner(lab.html, "data-veto-script", "code")[0]!).trim()}\n`;

/** The rules the way the lab reads them: one pattern and one reason from each marked script line. */
const RULES: readonly VetoRule[] = Array.from(
  lab.html.matchAll(/data-veto-rule="([^"]+)">block_if '<span data-veto-pattern>(.*?)<\/span>' '<span data-veto-reason>(.*?)<\/span>'<\/span>/g),
  (m) => ({ id: m[1]!, pattern: plain(m[2]!), reason: plain(m[3]!) }),
);

const PRESETS = inner(lab.html, "data-veto-preset", "button").map((label) => plain(label).trim());
const FIELD_START = /<input\b[^>]*\sdata-veto-input[^>]*>/.exec(lab.html)?.[0].match(/\svalue="([^"]*)"/)?.[1] ?? "";

const BLOCKED = "git push --force origin main";

/** Every command the lesson makes a claim about, with the verdict the hook should give and why. `null` means allowed. */
const VERDICTS: readonly (readonly [command: string, rule: string | null, why: string])[] = [
  ["git push --force origin main", "force_push", "the plain force push"],
  ["git push origin main", null, "an ordinary push"],
  ["git push --force-with-lease origin main", "force_push", "any option that starts with --force is a force push, on purpose"],
  ["git push --force-if-includes", "force_push", "any option that starts with --force"],
  ["git push -f", "force_push", "the short flag"],
  ["git push origin main -f", "force_push", "the flag after the branch"],
  ["git push -uf origin main", "force_push", "the short flag bundled with another"],
  ["git push origin +main", "force_push", "a leading plus sign forces without a flag"],
  ["git -C repo push -f", "force_push", "an option between git and push"],
  ["git -c k=v push --force", "force_push", "a config option between git and push"],
  ["git\tpush\t--force", "force_push", "tabs read as spaces"],
  ["git  push   --force", "force_push", "extra spaces change nothing"],
  ["GIT PUSH --FORCE", "force_push", "case is ignored"],
  ["git status && git push --force", "force_push", "a push later in a chain"],
  ["cd app; git push -f origin main", "force_push", "a push after a semicolon"],
  ["legit push --force", null, "git must be a word of its own"],
  ["git push origin main; rm -f notes.txt", null, "a -f that belongs to the next command is not the push's flag"],
  ["git push origin main && git tag -f v1", null, "a -f on the next command in a chain"],
  ["git push --follow-tags", null, "an option that only starts with f"],
  ["git push --no-verify", null, "an option with an f inside it"],
  ["git push -u origin fix-flaky", null, "a branch name that contains -f"],
  ["git push origin HEAD:refs/heads/feat", null, "a refspec without a plus sign"],
  ["git push origin :main", null, "deleting the remote branch is a known miss, stated on the page"],
  ["git commit -m 'pushed the fix'", null, "the word pushed in a commit message"],
  ["rm -rf /", "delete_root_or_home", "root"],
  ["rm -rf /*", "delete_root_or_home", "everything under root"],
  ["rm -rf ~", "delete_root_or_home", "home"],
  ["rm -rf ~/", "delete_root_or_home", "home with a slash"],
  ['rm -rf "$HOME"', "delete_root_or_home", "home through the variable, quoted"],
  ["rm -rf $HOME/", "delete_root_or_home", "home through the variable"],
  ["rm -rf ${HOME}", "delete_root_or_home", "home through the variable in braces"],
  ["rm -fr /", "delete_root_or_home", "the flags the other way round"],
  ["rm -r -f /", "delete_root_or_home", "split flags"],
  ["rm -rf -- /", "delete_root_or_home", "after the end-of-options mark"],
  ["rm --recursive --force /", "delete_root_or_home", "long options"],
  ["rm -rf /tmp ~", "delete_root_or_home", "home as the second target"],
  ["rm\t-rf\t/", "delete_root_or_home", "tabs read as spaces"],
  ["rm -Rf /", "delete_root_or_home", "case is ignored"],
  ["RM -RF /", "delete_root_or_home", "case is ignored"],
  ["rm  -rf   /", "delete_root_or_home", "extra spaces change nothing"],
  ["sudo rm -rf /", "delete_root_or_home", "with sudo in front"],
  ["cd /tmp && rm -rf /;ls", "delete_root_or_home", "root inside a chain"],
  ["rm -rf / --no-preserve-root", "delete_root_or_home", "root with another option after it"],
  ['echo "rm -rf /"', "delete_root_or_home", "a mention is blocked too, stated on the page"],
  ['rm -rf "$HOME/"', "delete_root_or_home", "home with a slash inside the quotes"],
  ['rm -rf "$HOME"/', "delete_root_or_home", "home with a slash after the quotes"],
  ['rm -rf "$HOME"/*', "delete_root_or_home", "everything in home, quoted"],
  ['rm -rf "${HOME}"', "delete_root_or_home", "home in braces and quotes"],
  ['rm -rf "${HOME:?}"', "delete_root_or_home", "home with a guard in the braces"],
  ['rm -rf -- "$HOME"', "delete_root_or_home", "quoted home after the end-of-options mark"],
  ['rm -rf "$HOME" /tmp', "delete_root_or_home", "quoted home as the first of two targets"],
  ['rm -rf "/"', "delete_root_or_home", "root in quotes"],
  ['rm -rf "~"', "delete_root_or_home", "a quoted tilde"],
  ['rm -rf "$HOME"/.cache/pip', null, "a cache directory under a quoted home"],
  ['rm -rf "${HOME}"/.npm', null, "a dot directory under a quoted home in braces"],
  ['rm -rf "/"tmp', null, "a path that only starts with a quoted slash"],
  ["rm -rf /tmp/prod", null, "the rule names root and home, not every path under root"],
  ["rm -rf ./build", null, "a path in the project"],
  ["rm -rf ~/code", null, "a directory inside home is not home"],
  ["rm -rf ~/.cache", null, "a dot directory inside home is not home"],
  ["rm -rf $HOMEWORK", null, "a different variable"],
  ["rm -rf /tmp/*", null, "a glob under another directory"],
  ["rm -f a.log > /dev/null", null, "a redirect to a path under root"],
  ["docker run --rm -w / img", null, "an option named --rm is not the rm command"],
  ["confirm -rf /", null, "rm must be a word of its own"],
  ["find / -delete", null, "a delete without rm is a known miss, stated on the page"],
  ["X=/; rm -rf $X", null, "a target hidden in a variable is a known miss, stated on the page"],
  ["sh cleanup.sh", null, "a script hides its commands, stated on the page"],
  ["echo 'exit 0' > ~/.config/minga/hooks/check-shell-command.sh", "minga_config", "overwriting the hook"],
  ["sed -i s/shell/none/ ~/.config/minga/config.exs", "minga_config", "editing the config"],
  ["rm -rf ~/.config/minga", "minga_config", "deleting the config directory passes the delete rule and is caught here"],
  ["cat $HOME/.CONFIG/Minga/config.exs", "minga_config", "reading the config, in any case"],
  ["ls ~/.config/minga", "minga_config", "the directory itself, with nothing after it"],
  ["ls ~/.config/minga/", "minga_config", "the directory with a slash"],
  ['cat "$HOME/.config/minga"', "minga_config", "the directory at the end of a quoted path"],
  ["cat ~/.config/mingarc", null, "a file whose name only starts the same way"],
  ["ls ~/.config/minga-old", null, "a directory whose name only starts the same way"],
  ["ls ~/.config/nvim", null, "another program's config"],
  ["npm test", null, "ordinary work"],
  ["mix test", null, "ordinary work"],
  ["ls -la", null, "ordinary work"],
];

describe("Lesson 04 hook tester: the rules are the script's rules", () => {
  it("reads one rule from each block_if line of the printed script, in order", () => {
    const printed = Array.from(SCRIPT.matchAll(/^block_if '(.*)' '(.*)'$/gm), (m) => ({ pattern: m[1]!, reason: m[2]! }));
    assert.equal(printed.length, 3, "the script has three rules");
    assert.deepEqual(
      RULES.map(({ pattern, reason }) => ({ pattern, reason })),
      printed,
    );
    assert.equal(new Set(RULES.map((rule) => rule.id)).size, RULES.length, "rule ids are unique");
  });

  it("keeps every pattern inside the part of the syntax that grep -E and JavaScript read the same way", () => {
    for (const rule of RULES) {
      const withoutEscapedDollar = rule.pattern.replaceAll("\\$", "");
      assert.doesNotMatch(withoutEscapedDollar, /\\/, `${rule.id}: no backslash escapes other than \\$`);
      const outsideBrackets = withoutEscapedDollar.replace(/\[[^\]]*\]/g, "");
      assert.doesNotMatch(rule.pattern, /\[\[[:=.]|'|\(\?/, `${rule.id}: no POSIX classes, quotes or JavaScript-only groups`);
      assert.doesNotMatch(outsideBrackets, /[.{}]/, `${rule.id}: no bare dot and no counted repeat`);
    }
  });

  it("the script names the message prefix the lab shows", () => {
    const prefix = plain(inner(lab.html, "data-veto-prefix", "span")[0] ?? "").trim();
    assert.notEqual(prefix, "");
    assert.ok(SCRIPT.includes(`echo "${prefix} $2" >&2; exit 1 ;;`));
  });
});

describe("Lesson 04 hook tester: verdicts", () => {
  for (const [command, rule, why] of VERDICTS) {
    it(`${rule === null ? "allows" : "blocks"} ${JSON.stringify(command)}: ${why}`, () => {
      const verdict = evaluateHook(command, RULES);
      assert.equal(verdict.rule?.id ?? null, rule);
      assert.equal(verdict.allowed, rule === null);
      assert.equal(verdict.exitCode, rule === null ? 0 : 1);
    });
  }

  it("judges a command one line at a time, as grep does", () => {
    assert.equal(evaluateHook("git push origin main\n-f", RULES).allowed, true);
    assert.equal(evaluateHook("echo start\nrm -rf /\n", RULES).rule?.id, "delete_root_or_home");
  });

  it("allows an empty command, as the script does", () => {
    assert.equal(evaluateHook("", RULES).allowed, true);
  });

  it("shows the payload with the keys Minga sends and the command untouched", () => {
    const payload = JSON.parse(hookPayload('  echo "hi"  ')) as Record<string, unknown>;
    assert.deepEqual(Object.keys(payload), ["event", "tool_call_id", "tool_name", "arguments"]);
    assert.deepEqual(payload, { event: "PreToolUse", tool_call_id: "tc_123", tool_name: "shell", arguments: { command: '  echo "hi"  ' } });
  });
});

describe("Lesson 04 hook tester: the lab agrees with the real script", () => {
  const run = (shell: string, args: readonly string[], input: string) => spawnSync(shell, args, { input, encoding: "utf8" });
  const has = (program: string): boolean => run("sh", ["-c", `command -v ${program}`], "").status === 0;
  const hasJq = has("jq");
  const prefix = plain(inner(lab.html, "data-veto-prefix", "span")[0] ?? "").trim();
  const commands = [...VERDICTS.map(([command]) => command), ...PRESETS, FIELD_START, "", "git push origin main\n-f", "echo start\nrm -rf /\n"];

  function withScript(script: string, check: (path: string) => void): void {
    const dir = mkdtempSync(join(tmpdir(), "minga-veto-"));
    try {
      const path = join(dir, "check-shell-command.sh");
      writeFileSync(path, script);
      chmodSync(path, 0o755);
      check(path);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  for (const shell of ["sh", "dash"]) {
    const skip = !hasJq ? "jq is not installed, so the printed script cannot run here" : has(shell) ? false : `${shell} is not installed`;
    it(`gives every command the exit code and message the printed script gives under ${shell}`, { skip }, () => {
      withScript(SCRIPT, (path) => {
        for (const command of commands) {
          const real = run(shell, [path], hookPayload(command));
          const ours = evaluateHook(command, RULES);
          assert.equal(real.status, ours.exitCode, `exit code for ${JSON.stringify(command)}`);
          assert.equal(real.stderr.trim(), ours.rule === null ? "" : `${prefix} ${ours.rule.reason}`, `message for ${JSON.stringify(command)}`);
        }
        assert.equal(run(shell, [path], "not json").status, 1, "a payload the script cannot read is a veto");
      });
    });
  }

  it("stops every command when a pattern is not a valid regular expression", { skip: hasJq ? false : "jq is not installed" }, () => {
    const broken = SCRIPT.replace("block_if '[.]config/minga(/|[^a-z0-9_.-]|$)'", "block_if '(unclosed'");
    assert.notEqual(broken, SCRIPT);
    withScript(broken, (path) => {
      const real = run("sh", [path], hookPayload("npm test"));
      assert.equal(real.status, 1);
      assert.match(real.stderr, /could not check the pattern/);
    });
  });
});

describe("Lesson 04 hook tester: presets", () => {
  it("offers four commands, and each button's label is the command it runs", () => {
    assert.deepEqual(PRESETS, ["git push --force origin main", "rm -rf /", "rm -rf /tmp/prod", "npm test"]);
    for (const preset of PRESETS) assert.equal(reduceVeto(createVetoState(""), { type: "preset", command: preset, field: "" }, RULES).last?.command, preset);
  });

  it("judges each preset by the rule as written", () => {
    assert.deepEqual(
      PRESETS.map((preset) => evaluateHook(preset, RULES).rule?.id ?? null),
      ["force_push", "delete_root_or_home", null, null],
    );
  });

  it("starts the field on the first blocked preset", () => {
    assert.equal(FIELD_START, BLOCKED);
    assert.equal(evaluateHook(FIELD_START, RULES).allowed, false);
  });
});

describe("Lesson 04 hook tester: nothing the reader typed is discarded", () => {
  const start = createVetoState(FIELD_START);

  it("lets a preset fill the field only while it is empty or still holds text the lab put there", () => {
    const table: readonly (readonly [field: string, labValue: string, fills: boolean])[] = [
      [FIELD_START, FIELD_START, true],
      ["", FIELD_START, true],
      ["   ", FIELD_START, true],
      ["git push origin main", FIELD_START, false],
      [`${FIELD_START} `, FIELD_START, false],
      ["my own command", FIELD_START, false],
    ];
    for (const [field, labValue, fills] of table) assert.equal(presetFillsField(field, labValue), fills, JSON.stringify(field));
  });

  it("runs a preset without touching text the reader typed", () => {
    for (const preset of PRESETS) {
      const after = reduceVeto(start, { type: "preset", command: preset, field: "my half-typed command" }, RULES);
      assert.equal(after.field, "my half-typed command");
      assert.equal(after.last?.command, preset);
    }
  });

  it("fills an untouched field, and then treats the preset's text as the lab's own", () => {
    const first = reduceVeto(start, { type: "preset", command: "rm -rf /", field: FIELD_START }, RULES);
    assert.equal(first.field, "rm -rf /");
    const second = reduceVeto(first, { type: "preset", command: "npm test", field: first.field }, RULES);
    assert.equal(second.field, "npm test");
    const edited = reduceVeto(second, { type: "preset", command: "rm -rf /", field: "npm test -- --watch" }, RULES);
    assert.equal(edited.field, "npm test -- --watch");
  });

  it("never changes the field when the reader runs it, whatever the verdict", () => {
    for (const field of ["", "   ", BLOCKED, "npm test", "  spaced  out  "]) assert.equal(reduceVeto(start, { type: "run", field }, RULES).field, field);
  });
});

describe("Lesson 04 hook tester: steps", () => {
  const start = createVetoState(FIELD_START);
  const run = (field: string): VetoEvent => ({ type: "run", field });
  const preset = (command: string, field: string): VetoEvent => ({ type: "preset", command, field });
  const play = (state: VetoState, ...events: VetoEvent[]): VetoState => events.reduce((s, event) => reduceVeto(s, event, RULES), state);

  const onEdited = play(start, run(BLOCKED));
  const onSafe = play(onEdited, run("git push origin main"));
  const finished = play(onSafe, run("npm test"));

  it("starts at rest on the first step with nothing run", () => {
    assert.deepEqual([start.caption, currentStep(start), start.runs, start.last], ["rest", "blocked", 0, null]);
  });

  const table: readonly { name: string; from: VetoState; event: VetoEvent; caption: CaptionId; done: readonly StepId[]; step: StepId | null }[] = [
    { name: "an empty field asks for a command and counts no run", from: start, event: run("  "), caption: "empty", done: [], step: "blocked" },
    { name: "an allowed command on step one points at a blocked one", from: start, event: run("npm test"), caption: "allowed_first", done: [], step: "blocked" },
    { name: "a blocked command finishes step one", from: start, event: run(BLOCKED), caption: "blocked", done: ["blocked"], step: "edited" },
    { name: "a blocked preset finishes step one too", from: start, event: preset("rm -rf /", FIELD_START), caption: "blocked", done: ["blocked"], step: "edited" },
    { name: "an edit that is still blocked stays on step two", from: onEdited, event: run("git push -f origin main"), caption: "still_blocked", done: ["blocked"], step: "edited" },
    { name: "a different program is not an edit", from: onEdited, event: run("npm test"), caption: "allowed_other", done: ["blocked"], step: "edited" },
    { name: "a preset is not an edit", from: onEdited, event: preset("npm test", BLOCKED), caption: "allowed_other", done: ["blocked"], step: "edited" },
    { name: "the same program without the blocked part finishes step two", from: onEdited, event: run("git push origin main"), caption: "edited", done: ["blocked", "edited"], step: "safe" },
    { name: "a blocked command on step three does not finish it", from: onSafe, event: run(BLOCKED), caption: "blocked_late", done: ["blocked", "edited"], step: "safe" },
    { name: "running the edited command again does not finish step three", from: onSafe, event: run(" git push origin main "), caption: "safe_same", done: ["blocked", "edited"], step: "safe" },
    { name: "a different allowed command finishes step three", from: onSafe, event: preset("npm test", "git push origin main"), caption: "safe", done: ["blocked", "edited", "safe"], step: null },
    { name: "after the steps a blocked command says so", from: finished, event: run("rm -rf ~"), caption: "free_blocked", done: ["blocked", "edited", "safe"], step: null },
    { name: "after the steps an allowed command says so", from: finished, event: run("rm -rf /tmp/prod"), caption: "free_allowed", done: ["blocked", "edited", "safe"], step: null },
  ];

  for (const row of table) {
    it(row.name, () => {
      const after = reduceVeto(row.from, row.event, RULES);
      assert.deepEqual([after.caption, after.done, currentStep(after)], [row.caption, row.done, row.step]);
    });
  }

  it("edits the blocked command it was last given, whichever one that was", () => {
    const state = play(start, preset("rm -rf /", FIELD_START), run("rm -rf ./build"));
    assert.equal(state.caption, "edited");
    assert.equal(editsBlockedCommand("sudo rm -rf ./build", "sudo rm -rf /"), true);
    assert.equal(editsBlockedCommand("ls", "sudo rm -rf /"), false);
    assert.equal(editsBlockedCommand("ls", null), false);
  });

  it("counts runs, keeps the last run, and reports a step as done once", () => {
    assert.equal(finished.runs, 3);
    assert.deepEqual(finished.last, { command: "npm test", verdict: { allowed: true, exitCode: 0, rule: null } });
    assert.deepEqual(newlyDone(start, onEdited), ["blocked"]);
    assert.deepEqual(newlyDone(onEdited, play(onEdited, run(BLOCKED))), []);
    assert.deepEqual(newlyDone(finished, play(finished, run(BLOCKED), run("npm test"))), []);
  });

  it("can reach every caption", () => {
    const seen = new Set<string>([start.caption, ...table.map((row) => reduceVeto(row.from, row.event, RULES).caption)]);
    assert.deepEqual(missing(CAPTION_IDS, [...seen]), []);
  });
});

describe("Lesson 04 hook tester: the page holds the words", () => {
  it("has the three steps in order, each with an instruction", () => {
    assert.deepEqual(lab.steps, [...STEP_IDS]);
    assert.equal(inner(lab.html, "data-lab-instruction", "p").filter((label) => plain(label).trim() !== "").length, STEP_IDS.length);
  });

  it("has exactly the captions the state can show, each with words", () => {
    assert.deepEqual([...lab.captions].sort(), [...CAPTION_IDS].sort());
    for (const caption of lab.html.matchAll(/data-lab-caption="([^"]+)">([\s\S]*?)<\/p>/g)) assert.notEqual(plain(caption[2]!).trim(), "", caption[1]!);
  });

  it("puts the caption line directly under the tester", () => {
    assert.match(lab.html, /<\/div>\s*<p class="lab-caption" data-lab-caption-line><\/p>\s*<ol data-lab-steps>/);
  });

  it("has a verdict word and a hook output for each state of the result", () => {
    assert.deepEqual(lab.attr("data-veto-verdict"), ["none", "blocked", "allowed"]);
    assert.deepEqual(lab.attr("data-veto-out"), ["none", "allowed", "blocked"]);
  });
});
