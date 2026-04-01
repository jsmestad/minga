#!/usr/bin/env python3
"""
Wave 2 NS-2: Migrate presentation modules to MingaEditor.*

Moves files from:
  lib/minga/editor/     -> lib/minga_editor/
  lib/minga/editor.ex   -> lib/minga_editor.ex  (entry point)
  lib/minga/shell/      -> lib/minga_editor/shell/
  lib/minga/shell.ex    -> lib/minga_editor/shell.ex
  lib/minga/input/      -> lib/minga_editor/input/
  lib/minga/input.ex    -> lib/minga_editor/input.ex
  lib/minga/frontend/   -> lib/minga_editor/frontend/
  lib/minga/frontend.ex -> lib/minga_editor/frontend.ex
  lib/minga/ui/         -> lib/minga_editor/ui/
  lib/minga/ui.ex       -> lib/minga_editor/ui.ex
  lib/minga/workspace/  -> lib/minga_editor/workspace/
  lib/minga/agent/*     -> lib/minga_editor/agent/  (remaining presentation)

Updates defmodule declarations and all references across the codebase.
"""

import os
import re
import subprocess
import sys
from collections import OrderedDict


def run(cmd, cwd=None, check=True):
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"ERROR: {cmd}", file=sys.stderr)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return result


def find_ex_files(base_dir, ext=".ex"):
    """Find all .ex files recursively under base_dir."""
    results = []
    for root, dirs, files in os.walk(base_dir):
        dirs[:] = sorted(d for d in dirs if d not in ("_build", "deps", ".git", "vendor"))
        for f in sorted(files):
            if f.endswith(ext):
                results.append(os.path.join(root, f))
    return results


def extract_module_name(filepath):
    """Extract the defmodule name from a file."""
    try:
        with open(filepath) as f:
            for line in f:
                m = re.match(r'defmodule\s+([\w.]+)\s+do', line)
                if m:
                    return m.group(1)
    except (IOError, UnicodeDecodeError):
        pass
    return None


def compute_new_module_name(old_name):
    """Convert Minga.X -> MingaEditor.X for presentation modules."""
    # Direct prefix replacements, ordered most-specific first
    prefixes = [
        ("Minga.Editor.",      "MingaEditor."),
        ("Minga.Editor",       "MingaEditor"),      # entry point
        ("Minga.Shell.",       "MingaEditor.Shell."),
        ("Minga.Shell",        "MingaEditor.Shell"),
        ("Minga.Input.",       "MingaEditor.Input."),
        ("Minga.Input",        "MingaEditor.Input"),
        ("Minga.Frontend.",    "MingaEditor.Frontend."),
        ("Minga.Frontend",     "MingaEditor.Frontend"),
        ("Minga.UI.",          "MingaEditor.UI."),
        ("Minga.UI",           "MingaEditor.UI"),
        ("Minga.Workspace.",   "MingaEditor.Workspace."),
        ("Minga.Workspace",    "MingaEditor.Workspace"),
        # Agent presentation modules
        ("Minga.Agent.",       "MingaEditor.Agent."),
    ]
    for old_prefix, new_prefix in prefixes:
        if old_name.startswith(old_prefix):
            return new_prefix + old_name[len(old_prefix):]
    return None


def compute_dest_path(src_path, base):
    """Compute destination path for a source file."""
    rel = os.path.relpath(src_path, base)

    # Entry point files directly under lib/minga/
    entry_points = {
        "lib/minga/editor.ex":    "lib/minga_editor.ex",
        "lib/minga/shell.ex":     "lib/minga_editor/shell.ex",
        "lib/minga/input.ex":     "lib/minga_editor/input.ex",
        "lib/minga/frontend.ex":  "lib/minga_editor/frontend.ex",
        "lib/minga/ui.ex":        "lib/minga_editor/ui.ex",
    }
    if rel in entry_points:
        return os.path.join(base, entry_points[rel])

    # Directory-based mapping
    dir_maps = [
        ("lib/minga/editor/",    "lib/minga_editor/"),
        ("lib/minga/shell/",     "lib/minga_editor/shell/"),
        ("lib/minga/input/",     "lib/minga_editor/input/"),
        ("lib/minga/frontend/",  "lib/minga_editor/frontend/"),
        ("lib/minga/ui/",        "lib/minga_editor/ui/"),
        ("lib/minga/workspace/", "lib/minga_editor/workspace/"),
        ("lib/minga/agent/",     "lib/minga_editor/agent/"),
    ]
    for old_dir, new_dir in dir_maps:
        if rel.startswith(old_dir):
            return os.path.join(base, new_dir + rel[len(old_dir):])

    return None


def compute_test_dest_path(src_path, base):
    """Compute destination path for a test file."""
    rel = os.path.relpath(src_path, base)

    dir_maps = [
        ("test/minga/editor/",       "test/minga_editor/"),
        ("test/minga/shell/",        "test/minga_editor/shell/"),
        ("test/minga/input/",        "test/minga_editor/input/"),
        ("test/minga/frontend/",     "test/minga_editor/frontend/"),
        ("test/minga/ui/",           "test/minga_editor/ui/"),
        ("test/minga/workspace/",    "test/minga_editor/workspace/"),
        ("test/minga/integration/",  "test/minga_editor/integration/"),
        ("test/minga/agent/",        "test/minga_editor/agent/"),
    ]
    for old_dir, new_dir in dir_maps:
        if rel.startswith(old_dir):
            return os.path.join(base, new_dir + rel[len(old_dir):])

    return None


def replace_modules_in_file(filepath, rename_map):
    """Apply all module renames in a file. Returns True if changed."""
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
    except (IOError, UnicodeDecodeError):
        return False

    new_content = content
    for old, new in rename_map:
        # Word-boundary aware: module name followed by non-identifier char or EOF
        pattern = re.escape(old) + r'(?=[^a-zA-Z0-9_]|$)'
        new_content = re.sub(pattern, new, new_content)

    if new_content != content:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(new_content)
        return True
    return False


def main():
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(base)
    print(f"Working directory: {base}")

    # ── Step 1: Discover all files to move ────────────────────────────────────
    print("\n=== Step 1: Discovering files to move ===")

    lib_files = []
    # Editor directory + entry point
    lib_files.append(os.path.join(base, "lib/minga/editor.ex"))
    lib_files.extend(find_ex_files(os.path.join(base, "lib/minga/editor")))
    # Shell
    if os.path.exists(os.path.join(base, "lib/minga/shell.ex")):
        lib_files.append(os.path.join(base, "lib/minga/shell.ex"))
    lib_files.extend(find_ex_files(os.path.join(base, "lib/minga/shell")))
    # Input
    if os.path.exists(os.path.join(base, "lib/minga/input.ex")):
        lib_files.append(os.path.join(base, "lib/minga/input.ex"))
    lib_files.extend(find_ex_files(os.path.join(base, "lib/minga/input")))
    # Frontend
    if os.path.exists(os.path.join(base, "lib/minga/frontend.ex")):
        lib_files.append(os.path.join(base, "lib/minga/frontend.ex"))
    lib_files.extend(find_ex_files(os.path.join(base, "lib/minga/frontend")))
    # UI
    if os.path.exists(os.path.join(base, "lib/minga/ui.ex")):
        lib_files.append(os.path.join(base, "lib/minga/ui.ex"))
    lib_files.extend(find_ex_files(os.path.join(base, "lib/minga/ui")))
    # Workspace
    lib_files.extend(find_ex_files(os.path.join(base, "lib/minga/workspace")))
    # Agent presentation (remaining files)
    lib_files.extend(find_ex_files(os.path.join(base, "lib/minga/agent")))

    print(f"  Found {len(lib_files)} lib files to move")

    # Test files
    test_files = []
    for d in ["editor", "shell", "input", "frontend", "ui", "workspace", "integration", "agent"]:
        test_dir = os.path.join(base, "test/minga", d)
        if os.path.isdir(test_dir):
            test_files.extend(find_ex_files(test_dir, ext=".exs"))
    print(f"  Found {len(test_files)} test files to move")

    # ── Step 2: Build module rename map ───────────────────────────────────────
    print("\n=== Step 2: Building module rename map ===")

    rename_map = []  # (old_name, new_name) sorted longest-first
    modules_seen = set()

    for filepath in lib_files:
        old_name = extract_module_name(filepath)
        if old_name and old_name not in modules_seen:
            new_name = compute_new_module_name(old_name)
            if new_name:
                rename_map.append((old_name, new_name))
                modules_seen.add(old_name)

    # Also capture test module names
    for filepath in test_files:
        old_name = extract_module_name(filepath)
        if old_name and old_name not in modules_seen:
            new_name = compute_new_module_name(old_name)
            if new_name:
                rename_map.append((old_name, new_name))
                modules_seen.add(old_name)

    # Sort longest-first to avoid partial matches
    rename_map.sort(key=lambda x: -len(x[0]))

    print(f"  Built {len(rename_map)} module renames")
    # Show first 10
    for old, new in rename_map[:10]:
        print(f"    {old} -> {new}")
    if len(rename_map) > 10:
        print(f"    ... and {len(rename_map) - 10} more")

    # ── Step 3: Move lib files ────────────────────────────────────────────────
    print("\n=== Step 3: Moving lib files ===")
    moved = 0
    for src in lib_files:
        dst = compute_dest_path(src, base)
        if not dst:
            print(f"  SKIP (no dest): {os.path.relpath(src, base)}")
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        run(f"git mv '{src}' '{dst}'", cwd=base)
        moved += 1
    print(f"  Moved {moved} lib files")

    # ── Step 4: Move test files ───────────────────────────────────────────────
    print("\n=== Step 4: Moving test files ===")
    moved_tests = 0
    for src in test_files:
        dst = compute_test_dest_path(src, base)
        if not dst:
            print(f"  SKIP (no dest): {os.path.relpath(src, base)}")
            continue
        if not os.path.exists(src):
            print(f"  SKIP (missing): {os.path.relpath(src, base)}")
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        run(f"git mv '{src}' '{dst}'", cwd=base)
        moved_tests += 1
    print(f"  Moved {moved_tests} test files")

    # ── Step 5: Apply module renames across ALL files ─────────────────────────
    print("\n=== Step 5: Renaming module references ===")
    total_changed = set()
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in ("_build", "deps", ".git", "vendor")]
        for fname in files:
            if fname.endswith((".ex", ".exs")):
                path = os.path.join(root, fname)
                if replace_modules_in_file(path, rename_map):
                    total_changed.add(path)

    print(f"  Updated references in {len(total_changed)} files")

    # ── Step 6: Fix test module defmodule declarations ────────────────────────
    print("\n=== Step 6: Fixing test module declarations ===")
    fixed_tests = 0
    for root, dirs, files in os.walk(os.path.join(base, "test/minga_editor")):
        dirs[:] = sorted(dirs)
        for fname in sorted(files):
            if fname.endswith(".exs"):
                path = os.path.join(root, fname)
                with open(path) as f:
                    content = f.read()
                new_content = content
                for old, new in rename_map:
                    # Fix defmodule declarations that still use old names
                    new_content = re.sub(
                        r'defmodule\s+' + re.escape(old) + r'(?=\s)',
                        f'defmodule {new}',
                        new_content
                    )
                if new_content != content:
                    with open(path, 'w') as f:
                        f.write(new_content)
                    fixed_tests += 1
    print(f"  Fixed {fixed_tests} test module declarations")

    print("\n=== Migration complete ===")
    print(f"  Lib files moved: {moved}")
    print(f"  Test files moved: {moved_tests}")
    print(f"  Module renames: {len(rename_map)}")
    print(f"  Files with reference updates: {len(total_changed)}")
    print("\nNext: run `mix compile --warnings-as-errors` to catch missed references.")


if __name__ == "__main__":
    main()
