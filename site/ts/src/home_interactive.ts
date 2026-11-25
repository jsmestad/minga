/* Homepage interactive enhancements: live Semantic Theme Role Switcher. */

export type MarksThemeId = "catppuccin_frappe" | "catppuccin_latte" | "astrodark" | "doom_one";

export interface SemanticThemeRoles {
  readonly label: string;
  readonly isLight: boolean;
  readonly bg: string;
  readonly border: string;
  readonly text: string;
  readonly minga: string;
  readonly mingaDim: string;
  readonly you: string;
  readonly needsYou: string;
  readonly waiting: string;
  readonly failure: string;
  readonly done: string;
}

export const SEMANTIC_MARK_THEMES: Record<MarksThemeId, SemanticThemeRoles> = {
  catppuccin_frappe: {
    label: "Catppuccin Frappé",
    isLight: false,
    bg: "#303446",
    border: "#414559",
    text: "#c6d0f5",
    minga: "#ca9ee6",
    mingaDim: "#75648e",
    you: "#8caaee",
    needsYou: "#ef9f76",
    waiting: "#838ba7",
    failure: "#e78284",
    done: "#a6d189",
  },
  catppuccin_latte: {
    label: "Catppuccin Latte",
    isLight: true,
    bg: "#eff1f5",
    border: "#ccd0da",
    text: "#4c4f69",
    minga: "#8839ef",
    mingaDim: "#b896e8",
    you: "#1e66f5",
    needsYou: "#d35400",
    waiting: "#7c7f93",
    failure: "#d20f39",
    done: "#388e25",
  },
  astrodark: {
    label: "AstroDark",
    isLight: false,
    bg: "#1a1d23",
    border: "#2a2f3a",
    text: "#adb0bb",
    minga: "#dd97f1",
    mingaDim: "#7c5888",
    you: "#50a4e9",
    needsYou: "#f5983a",
    waiting: "#696c76",
    failure: "#f8747e",
    done: "#75ad47",
  },
  doom_one: {
    label: "Doom One",
    isLight: false,
    bg: "#282c34",
    border: "#3f444a",
    text: "#bbc2cf",
    minga: "#c678dd",
    mingaDim: "#725180",
    you: "#51afef",
    needsYou: "#da8548",
    waiting: "#6d7580",
    failure: "#ff6c6b",
    done: "#98be65",
  },
};

function twistCrossSvg(minga: string, dim: string, bg: string): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M7 5 C7 11, 3 11, 3 17 L3 26" fill="none" stroke="${dim}" stroke-width="2.6" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="${bg}" stroke-width="5" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 26" fill="none" stroke="${minga}" stroke-width="2.6" stroke-linecap="round"/></svg>`;
}

function twistPairSvg(left: string, right: string, capBottom = false): string {
  const y2 = capBottom ? 19 : 26;
  const cap = capBottom ? ' stroke-linecap="round"' : "";
  return `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M3 0 L3 ${y2}" stroke="${left}" stroke-width="2.6"${cap}/><path d="M7 0 L7 ${y2}" stroke="${right}" stroke-width="2.6"${cap}/></svg>`;
}

function twistSingleSvg(color: string, opacity = 1, width = 1.6): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="26" viewBox="0 0 10 26" aria-hidden="true"><path d="M5 0 L5 26" stroke="${color}" stroke-opacity="${opacity}" stroke-width="${width}"/></svg>`;
}

export function mountMarksThemeSwitcher(root: HTMLElement): void {
  let activeTheme: MarksThemeId = "catppuccin_frappe";
  const section = root.closest("section");
  if (!section) return;

  function applyTheme(): void {
    const r = SEMANTIC_MARK_THEMES[activeTheme];
    const buttons = (Object.keys(SEMANTIC_MARK_THEMES) as MarksThemeId[])
      .map(
        (id) =>
          `<button type="button" class="seg-btn ${id === activeTheme ? "is-active" : ""}" data-mark-theme="${id}">${SEMANTIC_MARK_THEMES[id].label}</button>`,
      )
      .join("");

    root.innerHTML = `
      <div class="marks-theme-bar">
        <div class="marks-theme-head">
          <span class="marks-theme-k">PREVIEW SEMANTIC THEME ROLES LIVE</span>
          <div class="seg-group" role="group" aria-label="Preview Twist and Orbit theme roles">${buttons}</div>
        </div>
        <div class="marks-role-tokens" style="background:${r.bg};border-color:${r.border};color:${r.text};">
          <span><i style="background:${r.minga}"></i>minga <code>${r.minga}</code></span>
          <span><i style="background:${r.you}"></i>you <code>${r.you}</code></span>
          <span><i style="background:${r.needsYou}"></i>needs_you <code>${r.needsYou}</code></span>
          <span><i style="background:${r.failure}"></i>failure <code>${r.failure}</code></span>
          <span><i style="background:${r.done}"></i>done <code>${r.done}</code></span>
        </div>
      </div>
    `;

    const twistSwatches = section!.querySelectorAll<HTMLElement>(".twist-swatch");
    const twistSvgs = [
      twistCrossSvg(r.minga, r.mingaDim, r.bg),
      twistPairSvg(r.you, r.minga),
      twistSingleSvg(r.you, 1, 1.8),
      twistSingleSvg(r.minga, 0.55, 1.6),
    ];
    twistSwatches.forEach((el, idx) => {
      el.style.background = r.bg;
      el.style.borderColor = r.border;
      if (twistSvgs[idx]) el.innerHTML = twistSvgs[idx]!;
    });

    const orbitSvgs = [
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.5" fill="none" stroke="${r.minga}" stroke-opacity="0.32" stroke-width="1.5"/><path d="M8 2.5 A5.5 5.5 0 0 1 13.5 8" fill="none" stroke="${r.minga}" stroke-width="1.5" stroke-linecap="round"/><circle cx="13.5" cy="8" r="2.1" fill="${r.minga}"/></svg>`,
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6" fill="${r.needsYou}" fill-opacity="0.3"/><circle cx="8" cy="8" r="3.4" fill="${r.needsYou}"/></svg>`,
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="3" fill="none" stroke="${r.waiting}" stroke-width="1.6"/></svg>`,
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><rect x="4.6" y="4.6" width="6.8" height="6.8" rx="1.2" fill="${r.failure}" transform="rotate(45 8 8)"/></svg>`,
      `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="3.4" fill="${r.done}"/></svg>`,
    ];
    const orbitRows = section!.querySelectorAll<HTMLElement>(".orbit-row");
    orbitRows.forEach((row, idx) => {
      const existingSvg = row.querySelector("svg");
      if (existingSvg && orbitSvgs[idx]) {
        existingSvg.outerHTML = orbitSvgs[idx]!;
      }
    });
  }

  root.addEventListener("click", (event) => {
    const btn = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-mark-theme]");
    if (!btn) return;
    const id = btn.getAttribute("data-mark-theme") as MarksThemeId | null;
    if (id && id in SEMANTIC_MARK_THEMES) {
      activeTheme = id;
      applyTheme();
    }
  });

  applyTheme();
}
