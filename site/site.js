/* Minimal progressive enhancement for theme preference, mobile nav, tabs, and copy buttons. */
(() => {
  const root = document.documentElement;
  root.classList.add("js-enabled");

  const header = document.querySelector(".site-header");
  const navToggle = document.querySelector("[data-nav-toggle]");
  const navEl = document.getElementById("site-nav");
  if (header && navToggle && navEl) {
    function setNavOpen(open) {
      header.classList.toggle("nav-open", open);
      navToggle.setAttribute("aria-expanded", String(open));
      navToggle.textContent = open ? "Close" : "Menu";
    }

    navToggle.addEventListener("click", () => {
      setNavOpen(!header.classList.contains("nav-open"));
    });

    for (const link of navEl.querySelectorAll("a")) {
      link.addEventListener("click", () => setNavOpen(false));
    }

    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && header.classList.contains("nav-open")) {
        setNavOpen(false);
        navToggle.focus();
      }
    });

    const desktopMedia = window.matchMedia("(min-width: 861px)");
    if (typeof desktopMedia.addEventListener === "function") {
      desktopMedia.addEventListener("change", (event) => {
        if (event.matches) {
          setNavOpen(false);
        }
      });
    }
  }

  const storageKey = "minga-theme";
  const media = window.matchMedia("(prefers-color-scheme: light)");

  function effectiveTheme() {
    const explicit = root.getAttribute("data-theme");
    if (explicit === "light" || explicit === "dark") {
      return explicit;
    }
    return media.matches ? "light" : "dark";
  }

  function syncThemeButtons() {
    const current = effectiveTheme();
    const next = current === "dark" ? "light" : "dark";
    for (const button of document.querySelectorAll("[data-theme-toggle]")) {
      button.textContent = current === "dark" ? "Light" : "Dark";
      button.setAttribute("aria-label", `Switch to ${next} theme`);
      button.setAttribute("aria-pressed", String(current === "light"));
    }
  }

  for (const button of document.querySelectorAll("[data-theme-toggle]")) {
    button.addEventListener("click", () => {
      const next = effectiveTheme() === "dark" ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try {
        window.localStorage.setItem(storageKey, next);
      } catch (_) {
        /* Ignore storage errors in private browsing modes. */
      }
      syncThemeButtons();
    });
  }

  if (typeof media.addEventListener === "function") {
    media.addEventListener("change", syncThemeButtons);
  }
  syncThemeButtons();

  for (const group of document.querySelectorAll("[data-code-tabs]")) {
    const tabs = Array.from(group.querySelectorAll("[role=\"tab\"]"));
    const panels = Array.from(group.querySelectorAll("[role=\"tabpanel\"]"));
    const copyBtn = group.querySelector("[data-copy-target]");

    function activate(tab) {
      const targetId = tab.getAttribute("aria-controls");
      for (const item of tabs) {
        const selected = item === tab;
        item.setAttribute("aria-selected", String(selected));
        item.setAttribute("tabindex", selected ? "0" : "-1");
      }
      for (const panel of panels) {
        const active = panel.id === targetId;
        panel.hidden = !active;
        if (active && copyBtn) {
          const copyId = panel.getAttribute("data-copy-id");
          if (copyId) {
            copyBtn.setAttribute("data-copy-target", copyId);
            copyBtn.textContent = "Copy";
          }
        }
      }
    }

    for (const tab of tabs) {
      tab.addEventListener("click", () => activate(tab));
      tab.addEventListener("keydown", (event) => {
        const idx = tabs.indexOf(tab);
        let nextIdx = -1;
        if (event.key === "ArrowRight") nextIdx = (idx + 1) % tabs.length;
        else if (event.key === "ArrowLeft") nextIdx = (idx - 1 + tabs.length) % tabs.length;
        else if (event.key === "Home") nextIdx = 0;
        else if (event.key === "End") nextIdx = tabs.length - 1;
        if (nextIdx >= 0) {
          event.preventDefault();
          activate(tabs[nextIdx]);
          tabs[nextIdx].focus();
        }
      });
    }

    const initial = tabs.find((item) => item.getAttribute("aria-selected") === "true") || tabs[0];
    if (initial) {
      activate(initial);
    }
  }

  for (const button of document.querySelectorAll("[data-copy-target]")) {
    button.addEventListener("click", async () => {
      const targetId = button.getAttribute("data-copy-target");
      const codeEl = targetId ? document.getElementById(targetId) : null;
      if (!codeEl || !navigator.clipboard) {
        return;
      }
      const original = button.textContent;
      try {
        await navigator.clipboard.writeText(codeEl.textContent.trim());
        button.textContent = "Copied";
        window.setTimeout(() => {
          button.textContent = original;
        }, 1600);
      } catch (_) {
        button.textContent = "Copy failed";
        window.setTimeout(() => {
          button.textContent = original;
        }, 1600);
      }
    });
  }

  /* Lesson 02: Interactive v0.1.0 Key-Chord Trainer */
  const drillRoot = document.querySelector("[data-key-drill]");
  if (drillRoot) {
    const questions = [
      {
        prompt: "Open the file and buffer switcher (Pinned, Changed, Recent, Terminals).",
        options: ["SPC ,", "SPC a a", "SPC p h", "SPC g g"],
        answer: 0,
        explain: "SPC , (or SPC b b) opens the switcher drawer. Pinned files jump directly with SPC 1 to SPC 4."
      },
      {
        prompt: "Open *minga-tasks* to see running tasks, subagent trees, and needs-you approvals.",
        options: ["SPC a v", "SPC a a", "SPC a r", "SPC s u"],
        answer: 1,
        explain: "SPC a is the Minga group; SPC a a opens *minga-tasks* with needs-you rows sorted to the top."
      },
      {
        prompt: "Keep Minga's unreviewed change at the cursor while working inside a code buffer.",
        options: ["y", "SPC a y", "SPC a p", "SPC g s"],
        answer: 1,
        explain: "Inside a code file, y always stays Vim yank. Keeping Minga's change uses SPC a y (and SPC a d rejects)."
      },
      {
        prompt: "Open the decision-first Act Menu on whatever is under your cursor in Normal mode.",
        options: ["K", "g.", "SPC a i", "SPC c x"],
        answer: 1,
        explain: "g. opens the Act Menu in Normal mode and special buffers (Ctrl+. while typing, or right-click)."
      },
      {
        prompt: "Step to the next sibling worker inside Subagent Peek.",
        options: ["]]", "]h", "]d", "Ctrl+I"],
        answer: 0,
        explain: "]] and [[ step blocks and siblings in read-only buffers (Subagent Peek, task output, terminal blocks)."
      },
      {
        prompt: "Close a special buffer drawer like *minga-review* or *minga-tasks* and return focus.",
        options: ["q", "SPC b K", "SPC q q", "SPC a s"],
        answer: 0,
        explain: "q closes special buffers and splits like Emacs special-mode; esc cancels transient prompts and menus."
      },
      {
        prompt: "Open the edit timeline across both your edits and Minga's steps.",
        options: ["SPC a r", "SPC s q", "SPC s u", "SPC g B"],
        answer: 2,
        explain: "SPC s u opens the combined edit timeline (Doom convention). Plain u undoes only your own edits."
      },
      {
        prompt: "Queue a follow-up prompt into *minga-queue* from the conversation composer.",
        options: ["Enter (Normal)", "Option+Enter", "Cmd+.", "SPC a n"],
        answer: 1,
        explain: "Normal-mode Enter or Cmd+Enter steers immediately while Minga works; Option+Enter queues into *minga-queue*."
      }
    ];

    const promptEl = drillRoot.querySelector("[data-drill-prompt]");
    const optionsEl = drillRoot.querySelector("[data-drill-options]");
    const feedbackEl = drillRoot.querySelector("[data-drill-feedback]");
    const progressEl = drillRoot.querySelector("[data-drill-progress]");
    const nextBtn = drillRoot.querySelector("[data-drill-next]");
    const resetBtn = drillRoot.querySelector("[data-drill-reset]");

    let idx = 0;
    let score = 0;
    let answered = false;

    function renderDrill() {
      const q = questions[idx];
      answered = false;
      progressEl.textContent = `Question ${idx + 1} of ${questions.length} · Score ${score}`;
      promptEl.textContent = q.prompt;
      feedbackEl.textContent = "Pick the matching chord (or press 1 through 4) to see the grammar rule.";
      feedbackEl.className = "drill-feedback";
      nextBtn.hidden = true;
      nextBtn.textContent = idx === questions.length - 1 ? "See final score" : "Next question ->";

      optionsEl.innerHTML = "";
      q.options.forEach((opt, i) => {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "drill-opt";
        btn.setAttribute("data-drill-idx", String(i));
        btn.innerHTML = `<span class="drill-opt-num">${i + 1}</span><span class="drill-opt-key"></span>`;
        btn.querySelector(".drill-opt-key").textContent = opt;
        btn.addEventListener("click", () => choose(i));
        optionsEl.appendChild(btn);
      });
    }

    function choose(choiceIdx) {
      if (answered) return;
      answered = true;
      const q = questions[idx];
      const buttons = Array.from(optionsEl.querySelectorAll(".drill-opt"));
      buttons.forEach((btn, i) => {
        btn.disabled = true;
        if (i === q.answer) btn.classList.add("is-correct");
        if (i === choiceIdx && i !== q.answer) btn.classList.add("is-wrong");
      });
      if (choiceIdx === q.answer) {
        score += 1;
        feedbackEl.textContent = `Correct: ${q.explain}`;
        feedbackEl.className = "drill-feedback is-correct";
      } else {
        feedbackEl.textContent = `Answer is ${q.options[q.answer]}: ${q.explain}`;
        feedbackEl.className = "drill-feedback is-wrong";
      }
      progressEl.textContent = `Question ${idx + 1} of ${questions.length} · Score ${score}`;
      nextBtn.hidden = false;
    }

    nextBtn.addEventListener("click", () => {
      if (idx < questions.length - 1) {
        idx += 1;
        renderDrill();
      } else {
        promptEl.textContent = `Drill complete: ${score} of ${questions.length} correct.`;
        optionsEl.innerHTML = "";
        feedbackEl.textContent = score === questions.length
          ? "Every chord matched Minga's Doom-first key grammar. Ready for Lesson 03."
          : "Restart the drill anytime to lock in the remaining chords.";
        feedbackEl.className = "drill-feedback is-correct";
        nextBtn.hidden = true;
      }
    });

    resetBtn.addEventListener("click", () => {
      idx = 0;
      score = 0;
      renderDrill();
    });

    drillRoot.addEventListener("keydown", (event) => {
      if (event.key >= "1" && event.key <= "4" && !answered) {
        event.preventDefault();
        choose(Number(event.key) - 1);
      }
    });

    renderDrill();
  }

  /* Lesson 03: Interactive Twist & Per-Author Undo Lab */
  const labRoot = document.querySelector("[data-review-lab]");
  if (labRoot) {
    const SVG_CROSS = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M7 5 C7 11, 3 11, 3 17 L3 26" fill="none" stroke="#74628d" stroke-width="2.6" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="#303446" stroke-width="5" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="#ca9ee6" stroke-width="2.6" stroke-linecap="round"/></svg>';
    const SVG_CONT = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M3 0 L3 26" stroke="#74628d" stroke-width="2.6"/><path d="M7 0 L7 26" stroke="#ca9ee6" stroke-width="2.6"/></svg>';
    const SVG_SHARED = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M3 0 L3 26" stroke="#8caaee" stroke-width="2.6"/><path d="M7 0 L7 26" stroke="#ca9ee6" stroke-width="2.6"/></svg>';
    const SVG_END = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M3 0 L3 19" stroke="#74628d" stroke-width="2.6" stroke-linecap="round"/><path d="M7 0 L7 19" stroke="#ca9ee6" stroke-width="2.6" stroke-linecap="round"/></svg>';
    const SVG_KEPT = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M5 0 L5 26" stroke="#ca9ee6" stroke-opacity="0.48" stroke-width="1.6"/></svg>';

    const CODE_240_SHARED = '    <span class="cnum">529</span> -&gt; {<span class="cat">:overloaded</span>, backoff_ms(<span class="cnum">2</span>)} <span class="ccm"># your edit</span>';
    const CODE_240_ORIG = '    <span class="cnum">529</span> -&gt; {<span class="cat">:overloaded</span>, backoff_ms(<span class="cnum">1</span>)}';

    const statusEl = labRoot.querySelector("[data-lab-status]");
    const logEl = labRoot.querySelector("[data-lab-log]");
    const actMenu = labRoot.querySelector("[data-lab-act-menu]");
    const actTitle = labRoot.querySelector("[data-lab-act-title]");
    const keepDesc = labRoot.querySelector("[data-lab-keep-desc]");
    const rejectDesc = labRoot.querySelector("[data-lab-reject-desc]");
    const mlChange = labRoot.querySelector("[data-lab-ml-change]");
    const mlGit = labRoot.querySelector("[data-lab-ml-git]");
    const mlPos = labRoot.querySelector("[data-lab-ml-pos]");
    const code240 = labRoot.querySelector("[data-lab-code=\"240\"]");

    let state = {
      cursor: 1,
      c1: "unreviewed",
      c2: "unreviewed",
      userEdit: true,
      actOpen: false,
      note: "Cursor is on change 1 of 2 (lines 238 to 241). Line 240 has a shared blue+mauve strand because you edited inside Minga's change. Try pressing u Undo yours first."
    };

    function setGutter(lineNum, html) {
      const el = labRoot.querySelector(`[data-lab-gutter="${lineNum}"]`);
      if (el) el.innerHTML = html;
    }

    function renderLab() {
      const c1Lines = labRoot.querySelectorAll('[data-lab-change="1"]');
      const c2Lines = labRoot.querySelectorAll('[data-lab-change="2"]');

      c1Lines.forEach((el) => {
        el.classList.toggle("spine-line-hl", state.c1 === "unreviewed");
        el.classList.toggle("lab-line-rejected", state.c1 === "rejected");
        el.classList.toggle("lab-cursor", state.cursor === 1 && el.getAttribute("data-lab-line") === "238");
      });
      c2Lines.forEach((el) => {
        el.classList.toggle("spine-line-hl", state.c2 === "unreviewed");
        el.classList.toggle("lab-line-rejected", state.c2 === "rejected");
        el.classList.toggle("lab-cursor", state.cursor === 2 && el.getAttribute("data-lab-line") === "245");
      });

      if (state.c1 === "unreviewed") {
        setGutter("238", SVG_CROSS);
        setGutter("239", SVG_CONT);
        setGutter("240", state.userEdit ? SVG_SHARED : SVG_CONT);
        setGutter("241", SVG_END);
      } else if (state.c1 === "kept") {
        setGutter("238", SVG_KEPT);
        setGutter("239", SVG_KEPT);
        setGutter("240", SVG_KEPT);
        setGutter("241", SVG_KEPT);
      } else {
        setGutter("238", "");
        setGutter("239", "");
        setGutter("240", "");
        setGutter("241", "");
      }

      if (state.c2 === "unreviewed") setGutter("245", SVG_CROSS);
      else if (state.c2 === "kept") setGutter("245", SVG_KEPT);
      else setGutter("245", "");

      if (code240) {
        code240.innerHTML = state.userEdit ? CODE_240_SHARED : CODE_240_ORIG;
      }

      const remaining = (state.c1 === "unreviewed" ? 1 : 0) + (state.c2 === "unreviewed" ? 1 : 0);
      const personalLabel = state.userEdit && state.c1 !== "rejected" ? "1 personal edit" : "0 personal edits";
      statusEl.textContent = `${remaining} unreviewed ${remaining === 1 ? "change" : "changes"} · ${personalLabel}`;

      const curStatus = state.cursor === 1 ? state.c1 : state.c2;
      if (remaining > 0 && curStatus === "unreviewed") {
        const posIdx = state.cursor === 1 ? 1 : (state.c1 === "unreviewed" ? 2 : 1);
        mlChange.textContent = `change ${posIdx}/${remaining}`;
        mlChange.hidden = false;
      } else {
        mlChange.hidden = true;
      }

      const added = (state.c1 === "rejected" ? 0 : 4) + (state.c2 === "rejected" ? 0 : 1);
      mlGit.textContent = added > 0 ? `main +${added}` : "main clean";
      mlPos.textContent = state.cursor === 1 ? "238:3" : "245:1";

      const showAct = state.actOpen && curStatus === "unreviewed";
      actMenu.hidden = !showAct;
      if (showAct) {
        const linesCount = state.cursor === 1 ? 4 : 1;
        actTitle.textContent = `○ Minga's change ${state.cursor} of 2 · ${linesCount} ${linesCount === 1 ? "line" : "lines"} · unreviewed`;
        keepDesc.textContent = `accept ${linesCount} ${linesCount === 1 ? "line" : "lines"}`;
        rejectDesc.textContent = state.cursor === 1 ? "removes 4 lines, restores 1" : "removes 1 line";
      }

      logEl.textContent = state.note;
    }

    labRoot.addEventListener("click", (event) => {
      const btn = event.target.closest("[data-lab-action]");
      if (!btn) return;
      const action = btn.getAttribute("data-lab-action");

      if (action === "reset") {
        state = {
          cursor: 1,
          c1: "unreviewed",
          c2: "unreviewed",
          userEdit: true,
          actOpen: false,
          note: "Reset to initial state: 2 unreviewed Minga changes and 1 personal edit inside change 1 (line 240)."
        };
      } else if (action === "next") {
        state.actOpen = false;
        state.cursor = state.cursor === 1 ? 2 : 1;
        state.note = state.cursor === 1
          ? "]h jumped to change 1 (lines 238 to 241)."
          : "]h jumped to change 2 (line 245, backoff_ms/1).";
      } else if (action === "undo") {
        state.actOpen = false;
        if (state.userEdit && state.c1 !== "rejected") {
          state.userEdit = false;
          state.note = "u undid only your edit on line 240 (backoff_ms(2) -> backoff_ms(1)). Minga's braided changes stayed intact.";
        } else {
          state.note = "Nothing of yours left to undo. Minga's changes never disappear on u; use SPC a y to keep or SPC a d to reject.";
        }
      } else if (action === "keep") {
        state.actOpen = false;
        const key = state.cursor === 1 ? "c1" : "c2";
        if (state[key] !== "unreviewed") {
          state.note = `Change ${state.cursor} is already ${state[key]}. Press ]h to move to the other change or Reset.`;
        } else {
          state[key] = "kept";
          state.note = `SPC a y kept change ${state.cursor}. Its Twist faded to a muted accepted strand until your next commit.`;
          if (state.cursor === 1 && state.c2 === "unreviewed") state.cursor = 2;
          else if (state.cursor === 2 && state.c1 === "unreviewed") state.cursor = 1;
        }
      } else if (action === "reject") {
        state.actOpen = false;
        const key = state.cursor === 1 ? "c1" : "c2";
        if (state[key] !== "unreviewed") {
          state.note = `Change ${state.cursor} is already ${state[key]}. Press ]h to move to the other change or Reset.`;
        } else {
          state[key] = "rejected";
          state.note = `SPC a d rejected change ${state.cursor}. Minga's lines vanished cleanly without touching your undo history.`;
          if (state.cursor === 1 && state.c2 === "unreviewed") state.cursor = 2;
          else if (state.cursor === 2 && state.c1 === "unreviewed") state.cursor = 1;
        }
      } else if (action === "act") {
        const curStatus = state.cursor === 1 ? state.c1 : state.c2;
        if (curStatus !== "unreviewed") {
          state.actOpen = false;
          state.note = `Change ${state.cursor} is already ${curStatus}. Move to an unreviewed change with ]h or Reset.`;
        } else {
          state.actOpen = !state.actOpen;
          state.note = state.actOpen
            ? "g. opened the Act Menu leading with the Keep / Reject decision bar and exact line consequences."
            : "Closed the Act Menu.";
        }
      }

      renderLab();
    });

    renderLab();
  }

  /* Lesson 04: Interactive ~/.config/minga/config.exs Builder */
  const builderRoot = document.querySelector("[data-config-builder]");
  if (builderRoot) {
    const codeEl = document.getElementById("cfg-preview-code");
    const fields = builderRoot.querySelectorAll("[data-cfg-field], [data-cfg-opt]");

    function buildConfig() {
      const model = builderRoot.querySelector('[data-cfg-field="model"]').value;
      const theme = builderRoot.querySelector('[data-cfg-field="theme"]').value;
      const lines = builderRoot.querySelector('[data-cfg-field="lines"]').value;
      const tab = builderRoot.querySelector('[data-cfg-field="tab"]').value;
      const gofmt = builderRoot.querySelector('[data-cfg-opt="gofmt"]').checked;
      const hook = builderRoot.querySelector('[data-cfg-opt="hook"]').checked;
      const mcp = builderRoot.querySelector('[data-cfg-opt="mcp"]').checked;
      const ext = builderRoot.querySelector('[data-cfg-opt="ext"]').checked;

      const out = ["use Minga.Config", ""];
      out.push(`set :theme, :${theme}`);
      out.push(`set :line_numbers, :${lines}`);
      out.push(`set :tab_width, ${tab}`);
      if (model === "cua") {
        out.push("set :editing_model, :cua");
      }

      if (gofmt) {
        out.push("");
        out.push("for_filetype :go, tab_width: 4, indent_with: :tabs");
        out.push("");
        out.push("on :after_save, fn _buf, path ->");
        out.push('  if String.ends_with?(path, ".go") do');
        out.push('    System.cmd("gofmt", ["-w", path])');
        out.push("  end");
        out.push("end");
      }

      if (hook) {
        out.push("");
        out.push("set :agent_hooks, [");
        out.push("  %{");
        out.push('    event: "PreToolUse",');
        out.push('    tool: "shell",');
        out.push('    command: "~/.config/minga/hooks/check-shell-command.sh",');
        out.push("    timeout_ms: 10_000");
        out.push("  }");
        out.push("]");
      }

      if (mcp) {
        out.push("");
        out.push("set :agent_mcp_servers, [");
        out.push("  %{");
        out.push('    name: "github",');
        out.push('    command: "npx",');
        out.push('    args: ["-y", "@modelcontextprotocol/server-github"],');
        out.push('    env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => System.fetch_env!("GITHUB_TOKEN")}');
        out.push("  }");
        out.push("]");
      }

      if (ext) {
        out.push("");
        out.push("extension :minga_git_extended,");
        out.push('  hex: "minga_git_extended",');
        out.push('  version: "~> 0.1",');
        out.push("  load_policy: {:on_command, [:git_log]}");
      }

      if (codeEl) {
        codeEl.textContent = out.join("\n");
      }
    }

    for (const input of fields) {
      input.addEventListener("change", buildConfig);
    }
    buildConfig();
  }
})();
