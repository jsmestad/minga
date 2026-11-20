.PHONY: help clean done lint lint.full lint.format lint.credo lint.credo.changed lint.compile lint.dialyzer lint.dialyzer.incremental lint.ex-dna lint.reach lint.fix test test.llm \
       native.support native.tui native.go-tui xcodegen-install xcodegen-generate \
       release release-tui release-mac install install-tui install-mac uninstall

.DEFAULT_GOAL := help

help:
	@printf "\n\033[1;35m╭────────────────────────────────────────────╮\033[0m\n"
	@printf "\033[1;35m│\033[0m  \033[1mMinga developer commands\033[0m                 \033[1;35m│\033[0m\n"
	@printf "\033[1;35m╰────────────────────────────────────────────╯\033[0m\n\n"
	@printf "\033[1;36mRun the editor\033[0m\n"
	@printf "  \033[1mbin/minga\033[0m          Launch the Go/Bubble Tea TUI\n"
	@printf "  \033[1mbin/minga +gui\033[0m     Launch the native macOS GUI\n\n"
	@printf "  \033[1mmake clean\033[0m         Reset this worktree's Minga development profile\n\n"
	@printf "\033[1;36mQuality checks\033[0m\n"
	@printf "  \033[1mmake done\033[0m          Pre-review gate: lint + ExUnit + changed macOS build/tests (~4m warm on Apple silicon, ~2m without macOS changes)\n"
	@printf "  \033[1mmake lint\033[0m          Fast local gate: format, changed Credo, ExDNA, compile, incremental Dialyzer, Reach arch policy (parallel, ~25s warm)\n"
	@printf "  \033[1mmake lint.full\033[0m     Full gate: format, Credo, ExDNA, compile, classic Dialyzer, Reach arch and smells\n"
	@printf "  \033[1mmake lint.fix\033[0m      Run format and strict Credo\n"
	@printf "  \033[1mmake test\033[0m          Build parser support and run the full ExUnit suite\n"
	@printf "  \033[1mmake test.llm\033[0m      Build parser support and run LLM-friendly tests\n\n"
	@printf "\033[1;36mNative builds\033[0m\n"
	@printf "  \033[1mmake native.support\033[0m Build parser and hook-runner support binaries\n"
	@printf "  \033[1mmake native.tui\033[0m     Build the TUI binaries (Go renderer, parser)\n"
	@printf "  \033[1mmake native.go-tui\033[0m  Build only the Go TUI renderer\n"
	@printf "  \033[1mmake xcodegen-install\033[0m Install the pinned XcodeGen locally\n"
	@printf "  \033[1mmake xcodegen-generate\033[0m Regenerate the macOS Xcode project\n\n"
	@printf "\033[1;36mBuild and install\033[0m\n"
	@printf "  \033[1mmake release\033[0m       Build release artifacts for this platform\n"
	@printf "  \033[1mmake release-tui\033[0m   Build the TUI release\n"
	@printf "  \033[1mmake release-mac\033[0m   Build the macOS GUI app\n"
	@printf "  \033[1mmake install\033[0m       Install available local artifacts\n"
	@printf "  \033[1mmake uninstall\033[0m     Remove installed local artifacts\n\n"
	@printf "\033[2mTip: pass a file to a launcher, for example \033[0m\033[1mbin/minga-go README.md\033[0m\n\n"

clean:
	@python3 scripts/dev_profile.py clean

# ── Platform detection ──────────────────────────────────────────────────
OS       := $(shell uname -s)
ARCH     := $(shell uname -m)

# Normalize the CPU name to match release artifact names.
ifeq ($(ARCH),arm64)
  ARCH := aarch64
endif

ifeq ($(OS),Darwin)
  TUI_TARGET := minga_macos_$(ARCH)
  STANDALONE_INSTALL_NAME := minga-tui
else
  TUI_TARGET := minga_linux_$(ARCH)
  STANDALONE_INSTALL_NAME := minga
endif

# ── Install paths ───────────────────────────────────────────────────────
PREFIX  ?= $(HOME)/.local
BINDIR   = $(PREFIX)/bin
APP_DIR ?= /Applications

TUI_RELEASE := _build/prod/rel/minga
TUI_ARCHIVE := _build/prod/$(TUI_TARGET).tar.gz
TUI_INSTALL_DIR := $(PREFIX)/libexec/minga-tui

# ── Lint ────────────────────────────────────────────────────────────────

# Local lint gates. scripts/lint runs independent checks concurrently, replays each log in a fixed order, skips the compile chain on docs-only branches, and keeps Reach smells (advisory-only, exit 0, about 4 minutes) in the full gate only; the Reach arch policy is a 12s gate in both.
done:
	@scripts/lint done

lint:
	@scripts/lint fast

lint.full:
	@scripts/lint full

lint.format:
	mix format --check-formatted

lint.credo:
	mix credo --strict

lint.credo.changed:
	scripts/credo_changed

lint.compile:
	mix compile --warnings-as-errors

lint.dialyzer:
	mix dialyzer

lint.dialyzer.incremental:
	mix dialyzer.incremental

lint.ex-dna:
	mix ex_dna --max-clones 0

lint.reach:
	mix reach.check --arch --smells

lint.fix:
	mix format
	mix credo --strict

# ── Test ────────────────────────────────────────────────────────────────

test: native.support
	mix test

test.llm: native.support
	mix test.llm

# ── Native builds ───────────────────────────────────────────────────────

native.support:
	mix native.build.support

native.tui:
	mix native.build.tui

native.go-tui:
	mix native.build.go_tui

# ── XcodeGen ────────────────────────────────────────────────────────────

XCODEGEN_DIR := $(CURDIR)/.tools/xcodegen
XCODEGEN_BIN := $(XCODEGEN_DIR)/xcodegen/bin/xcodegen

xcodegen-install:
	@scripts/install_xcodegen "$(XCODEGEN_DIR)"

xcodegen-generate: xcodegen-install
	@cd macos && "$(XCODEGEN_BIN)" generate

# ── Release (build without installing) ─────────────────────────────────

ifeq ($(OS),Linux)
release-tui: export EXQLITE_USE_SYSTEM :=
endif

release-tui:
	@echo "Building native TUI release for $(TUI_TARGET)..."
	MIX_ENV=prod mix deps.get --only prod
	@if [ "$(OS)" = Linux ]; then MIX_ENV=prod mix deps.clean exqlite --build; fi
	MIX_ENV=prod mix native.build.tui
	MIX_ENV=prod mix release.tui --overwrite
	@scripts/check-release-contents "$(TUI_RELEASE)" --runtime-receipt "$$MINGA_RELEASE_ERTS_RECEIPT"
	COPYFILE_DISABLE=1 tar -czf "$(TUI_ARCHIVE)" -C "$(dir $(TUI_RELEASE))" "$(notdir $(TUI_RELEASE))"
	@echo "TUI archive: $(TUI_ARCHIVE)"

release-mac:
ifeq ($(OS),Darwin)
release-mac: xcodegen-install
	@command -v xcodebuild >/dev/null 2>&1 || { echo "\033[31mError: xcodebuild not found. Install Xcode from the App Store.\033[0m"; exit 1; }
	@echo "Building macOS GUI app..."
	PATH="$(XCODEGEN_DIR)/xcodegen/bin:$$PATH" MIX_ENV=prod mix app.assemble
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
	@mkdir -p "$(BINDIR)" "$(TUI_INSTALL_DIR)"
	rsync -a --delete "$(TUI_RELEASE)/" "$(TUI_INSTALL_DIR)/"
	ln -sfn "$$(cd "$(TUI_INSTALL_DIR)" && pwd -P)/launchers/minga" "$(BINDIR)/$(STANDALONE_INSTALL_NAME)"
	@"$(BINDIR)/$(STANDALONE_INSTALL_NAME)" --version

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
		IO.write(Path.join(String.trim(dir), String.trim(product)))' 2>/dev/null); \
	if [ -z "$$APP_PATH" ] || [ ! -d "$$APP_PATH" ]; then \
		echo "\033[31mError: Could not locate Minga.app after build.\033[0m"; exit 1; \
	fi; \
	rm -rf "$(APP_DIR)/Minga.app" && \
	cp -R "$$APP_PATH" "$(APP_DIR)/Minga.app" || { \
		echo "\033[33mPermission denied. Try: sudo make install-mac\033[0m"; exit 1; \
	}; \
	mkdir -p "$(BINDIR)"; \
	ln -sf "$(APP_DIR)/Minga.app/Contents/Resources/bin/minga" "$(BINDIR)/minga"; \
	ln -sf "$(APP_DIR)/Minga.app/Contents/Resources/bin/minga-tui" "$(BINDIR)/minga-tui"; \
	echo "\033[32mInstalled Minga.app and launchers to $(BINDIR)\033[0m"
else
	@echo "\033[31mError: make install-mac is only available on macOS.\033[0m"; exit 1
endif

ifeq ($(OS),Darwin)
install: install-mac
else
install: install-tui
endif

# ── Uninstall ───────────────────────────────────────────────────────────

uninstall:
	@rm -f "$(BINDIR)/minga" && echo "Removed $(BINDIR)/minga" || true
	@rm -f "$(BINDIR)/minga-tui" && echo "Removed $(BINDIR)/minga-tui" || true
	@rm -rf "$(TUI_INSTALL_DIR)"
ifeq ($(OS),Darwin)
	@rm -rf "$(APP_DIR)/Minga.app" && echo "Removed $(APP_DIR)/Minga.app" || true
endif
	@echo "\033[32mUninstall complete.\033[0m"
