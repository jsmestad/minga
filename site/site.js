/* Minimal progressive enhancement for theme preference and install copy buttons. */
(() => {
  const root = document.documentElement;
  root.classList.add("js-enabled");

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
})();
