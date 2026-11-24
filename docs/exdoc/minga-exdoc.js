(() => {
  const EXDOC_KEY = "ex_doc:settings";
  const SITE_KEY = "minga-theme";

  function readExDocSettings() {
    try {
      const raw = window.localStorage.getItem(EXDOC_KEY);
      return raw ? JSON.parse(raw) : {};
    } catch (_) {
      return {};
    }
  }

  function writeThemes(theme) {
    try {
      window.localStorage.setItem(SITE_KEY, theme);
      const settings = readExDocSettings();
      settings.theme = theme;
      window.localStorage.setItem(EXDOC_KEY, JSON.stringify(settings));
    } catch (_) {}
  }

  function currentTheme() {
    return document.body.classList.contains("dark") ? "dark" : "light";
  }

  function updateToggleLabel(btn) {
    if (!btn) return;
    const isDark = currentTheme() === "dark";
    btn.textContent = isDark ? "Light" : "Dark";
    btn.setAttribute("aria-label", isDark ? "Switch to light theme" : "Switch to dark theme");
  }

  function init() {
    const topbar = document.getElementById("minga-topbar");
    if (topbar && document.body.firstElementChild !== topbar) {
      document.body.prepend(topbar);
    }

    const themeBtn = document.querySelector("[data-minga-theme-toggle]");
    const navBtn = document.querySelector("[data-minga-nav-toggle]");
    const nav = document.getElementById("minga-topbar-nav");

    updateToggleLabel(themeBtn);

    if (themeBtn) {
      themeBtn.addEventListener("click", () => {
        const next = currentTheme() === "dark" ? "light" : "dark";
        document.body.classList.toggle("dark", next === "dark");
        document.documentElement.setAttribute("data-theme", next);
        writeThemes(next);
        updateToggleLabel(themeBtn);
      });
    }

    if (navBtn && topbar && nav) {
      navBtn.addEventListener("click", () => {
        const open = topbar.classList.toggle("nav-open");
        navBtn.setAttribute("aria-expanded", String(open));
      });

      document.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && topbar.classList.contains("nav-open")) {
          topbar.classList.remove("nav-open");
          navBtn.setAttribute("aria-expanded", "false");
        }
      });
    }

    // Keep minga-theme and toggle button synced if user switches theme inside ExDoc Settings
    const observer = new MutationObserver(() => {
      const theme = currentTheme();
      document.documentElement.setAttribute("data-theme", theme);
      try {
        window.localStorage.setItem(SITE_KEY, theme);
      } catch (_) {}
      updateToggleLabel(themeBtn);
    });
    observer.observe(document.body, { attributes: true, attributeFilter: ["class"] });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
