/* Lesson 01 (/getting-started): Adaptive Quickstart Runbook filter bar. */

import { completeMission } from "./progress.ts";

export function mountRunbookFilter(root: HTMLElement): void {
  let platform: "apple-silicon" | "source" = "apple-silicon";
  let client: "mac" | "cli" = "mac";
  let keys: "vim" | "cua" = "vim";

  function sync(): void {
    const brewTab = document.getElementById("tab-gs-brew");
    const sourceTab = document.getElementById("tab-gs-source");
    if (platform === "apple-silicon") brewTab?.click();
    else sourceTab?.click();

    const summaryEl = root.querySelector<HTMLElement>("[data-rb-summary]");
    if (summaryEl) {
      const installPart =
        platform === "apple-silicon"
          ? client === "mac"
            ? "brew install --cask jsmestad/minga/minga-mac && open -a Minga"
            : "brew install jsmestad/minga/minga && minga path/to/project"
          : client === "mac"
            ? "Build from source (requires Xcode) and launch bin/minga-mac"
            : "Build from source with mise/asdf and launch bin/minga";
      const keyPart =
        keys === "cua"
          ? "Add `set :editing_model, :cua` in ~/.config/minga/config.exs for desktop shortcuts."
          : "Vim modal defaults are active out of the box; press SPC to discover every group.";
      summaryEl.innerHTML = `<strong>Tailored path:</strong> <code>${installPart}</code> · ${keyPart}`;
    }

    root.querySelectorAll<HTMLButtonElement>("[data-rb-platform]").forEach((b) => {
      b.classList.toggle("is-active", b.getAttribute("data-rb-platform") === platform);
    });
    root.querySelectorAll<HTMLButtonElement>("[data-rb-client]").forEach((b) => {
      b.classList.toggle("is-active", b.getAttribute("data-rb-client") === client);
    });
    root.querySelectorAll<HTMLButtonElement>("[data-rb-keys]").forEach((b) => {
      b.classList.toggle("is-active", b.getAttribute("data-rb-keys") === keys);
    });
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;
    const pBtn = target.closest<HTMLElement>("[data-rb-platform]");
    if (pBtn) {
      platform = pBtn.getAttribute("data-rb-platform") === "source" ? "source" : "apple-silicon";
      completeMission("getting-started", "configured");
      sync();
      return;
    }
    const cBtn = target.closest<HTMLElement>("[data-rb-client]");
    if (cBtn) {
      client = cBtn.getAttribute("data-rb-client") === "cli" ? "cli" : "mac";
      completeMission("getting-started", "configured");
      sync();
      return;
    }
    const kBtn = target.closest<HTMLElement>("[data-rb-keys]");
    if (kBtn) {
      keys = kBtn.getAttribute("data-rb-keys") === "cua" ? "cua" : "vim";
      completeMission("getting-started", "configured");
      sync();
    }
  });

  sync();
}
