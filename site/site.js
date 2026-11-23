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
