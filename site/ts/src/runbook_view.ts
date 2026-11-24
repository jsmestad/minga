/* Lesson 01 (/getting-started): Adaptive Quickstart Runbook filter bar. */

import { completeMission } from "./progress.ts";

export function mountRunbookFilter(root: HTMLElement): void {
  let platform: "apple-silicon" | "arch" | "deb" | "rpm" | "source" = "apple-silicon";
  let client: "mac" | "cli" = "mac";
  let keys: "vim" | "cua" = "vim";

  function sync(): void {
    const tabs = {
      "apple-silicon": "tab-gs-brew",
      arch: "tab-gs-arch",
      deb: "tab-gs-deb",
      rpm: "tab-gs-rpm",
      source: "tab-gs-source",
    } as const;
    document.getElementById(tabs[platform])?.click();

    const summaryEl = root.querySelector<HTMLElement>("[data-rb-summary]");
    if (summaryEl) {
      const installPart =
        platform === "apple-silicon"
          ? client === "mac"
            ? "brew install --cask jsmestad/minga/minga-mac && open -a Minga"
            : "brew install jsmestad/minga/minga && minga path/to/project"
          : platform === "arch"
            ? "Add [minga] repo on Arch / Omarchy, then sudo pacman -Syu minga && minga ."
            : platform === "deb"
              ? "Add minga.sources on Ubuntu / Debian, then sudo apt update && sudo apt install minga"
              : platform === "rpm"
                ? "Add minga.repo on Fedora, then sudo dnf install minga"
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
      const chosen = pBtn.getAttribute("data-rb-platform");
      platform =
        chosen === "arch" || chosen === "deb" || chosen === "rpm" || chosen === "source"
          ? chosen
          : "apple-silicon";
      if (platform === "arch" || platform === "deb" || platform === "rpm") {
        client = "cli";
      }
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
