.PHONY: lint lint.format lint.credo lint.compile lint.dialyzer lint.fix test test.llm \
       release release-tui release-mac install install-tui install-mac uninstall

# ── Platform detection ──────────────────────────────────────────────────
OS       := $(shell uname -s)
ARCH     := $(shell uname -m)

# Normalize macOS arm64 → aarch64 to match Burrito naming
ifeq ($(ARCH),arm64)
  ARCH := aarch64
endif

ifeq ($(OS),Darwin)
  BURRITO_TARGET := minga_macos_$(ARCH)
else
  BURRITO_TARGET := minga_linux_$(ARCH)
endif

# ── Install paths ───────────────────────────────────────────────────────
PREFIX  ?= $(HOME)/.local
BINDIR   = $(PREFIX)/bin
APP_DIR ?= /Applications

# Burrito unpacks the binary's payload into a versioned cache dir named
# <app>_erts-<ertsver>_<appver> and only re-extracts when that dir is absent.
# The app version rarely changes during local dev, so a fresh `make install`
# would otherwise keep running the previously extracted code. We clear minga's
# extraction on install to force a re-unpack of the new payload.
ifeq ($(OS),Darwin)
  BURRITO_INSTALL_DIR := $(HOME)/Library/Application Support/.burrito
else
  XDG_DATA_HOME ?= $(HOME)/.local/share
  BURRITO_INSTALL_DIR := $(XDG_DATA_HOME)/.burrito
endif

# ── Lint ────────────────────────────────────────────────────────────────

# Run all lint checks. Each step runs independently so dialyzer always
# runs even if an earlier step fails. Failures are collected and reported
# at the end.
lint:
	@failed=""; \
	mix format --check-formatted || failed="$$failed format"; \
	mix credo --strict || failed="$$failed credo"; \
	mix compile --warnings-as-errors || failed="$$failed compile"; \
	mix dialyzer || failed="$$failed dialyzer"; \
	if [ -n "$$failed" ]; then \
		echo "\n\033[31mFailed checks:$$failed\033[0m"; \
		exit 1; \
	else \
		echo "\n\033[32mAll lint checks passed.\033[0m"; \
	fi

lint.format:
	mix format --check-formatted

lint.credo:
	mix credo --strict

lint.compile:
	mix compile --warnings-as-errors

lint.dialyzer:
	mix dialyzer

lint.fix:
	mix format
	mix credo --strict

# ── Test ────────────────────────────────────────────────────────────────

test:
	mix test

test.llm:
	mix test.llm

# ── Release (build without installing) ─────────────────────────────────

release-tui:
	@echo "Building TUI release for $(BURRITO_TARGET)..."
	MIX_ENV=prod mix deps.get --only prod
	MIX_ENV=prod mix release minga --overwrite
	@scripts/check-release-contents _build/prod/rel/minga
	@echo "\033[32mTUI binary: burrito_out/$(BURRITO_TARGET)\033[0m"

release-mac:
ifeq ($(OS),Darwin)
	@command -v xcodebuild >/dev/null 2>&1 || { echo "\033[31mError: xcodebuild not found. Install Xcode from the App Store.\033[0m"; exit 1; }
	@command -v xcodegen >/dev/null 2>&1 || { echo "\033[31mError: xcodegen not found. Install with: brew install xcodegen\033[0m"; exit 1; }
	@echo "Building macOS GUI app..."
	MIX_ENV=prod mix app.assemble
	@echo "\033[32mMinga.app built successfully.\033[0m"
else
	@echo "\033[31mError: make release-mac is only available on macOS.\033[0m"; exit 1
endif

release: release-tui
ifeq ($(OS),Darwin)
release: release-mac
endif

# ── Install ─────────────────────────────────────────────────────────────

install-tui: release-tui
	@mkdir -p "$(BINDIR)"
	cp "burrito_out/$(BURRITO_TARGET)" "$(BINDIR)/minga"
	chmod +x "$(BINDIR)/minga"
	@# Force Burrito to re-extract the new payload (see BURRITO_INSTALL_DIR above).
	@rm -rf "$(BURRITO_INSTALL_DIR)"/minga_erts-*
	@echo "\033[32mInstalled minga to $(BINDIR)/minga\033[0m"
	@"$(BINDIR)/minga" --version || true

install-mac: release-mac
ifeq ($(OS),Darwin)
	@echo "Installing Minga.app to $(APP_DIR)..."
	@APP_PATH=$$(MIX_ENV=prod mix run --no-start -e ' \
		project_path = Path.join([File.cwd!(), "macos", "Minga.xcodeproj"]); \
		{output, 0} = System.cmd("xcodebuild", [ \
			"-project", project_path, "-scheme", "Minga", \
			"-configuration", "Release", "-showBuildSettings"], stderr_to_stdout: true); \
		[dir] = Regex.run(~r/BUILT_PRODUCTS_DIR = (.+)/, output, capture: :all_but_first); \
		[product] = Regex.run(~r/FULL_PRODUCT_NAME = (.+)/, output, capture: :all_but_first); \
		IO.write(Path.join(String.trim(dir), String.trim(product)))'); \
	if [ -z "$$APP_PATH" ] || [ ! -d "$$APP_PATH" ]; then \
		echo "\033[31mError: Could not locate Minga.app after build.\033[0m"; exit 1; \
	fi; \
	cp -R "$$APP_PATH" "$(APP_DIR)/Minga.app" || { \
		echo "\033[33mPermission denied. Try: sudo make install-mac\033[0m"; exit 1; \
	}; \
	echo "\033[32mInstalled Minga.app to $(APP_DIR)/Minga.app\033[0m"
else
	@echo "\033[31mError: make install-mac is only available on macOS.\033[0m"; exit 1
endif

install: install-tui
ifeq ($(OS),Darwin)
install: install-mac
endif

# ── Uninstall ───────────────────────────────────────────────────────────

uninstall:
	@rm -f "$(BINDIR)/minga" && echo "Removed $(BINDIR)/minga" || true
ifeq ($(OS),Darwin)
	@rm -rf "$(APP_DIR)/Minga.app" && echo "Removed $(APP_DIR)/Minga.app" || true
endif
	@echo "\033[32mUninstall complete.\033[0m"
