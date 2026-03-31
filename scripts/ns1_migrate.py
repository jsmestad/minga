#!/usr/bin/env python3
"""
Wave 2 NS-1: Migrate domain agent modules from Minga.Agent.* -> MingaAgent.*

Moves files from lib/minga/agent/ -> lib/minga_agent/
Updates defmodule declarations and all references across the codebase.
"""

import os
import re
import subprocess
import sys

# ── Files to move ──────────────────────────────────────────────────────────────
# Each entry: (src relative to lib/, dst relative to lib/)
FILES_TO_MOVE = [
    # Core session/supervisor
    ("minga/agent/session.ex",          "minga_agent/session.ex"),
    ("minga/agent/supervisor.ex",       "minga_agent/supervisor.ex"),
    # Providers
    ("minga/agent/provider.ex",         "minga_agent/provider.ex"),
    ("minga/agent/provider_resolver.ex","minga_agent/provider_resolver.ex"),
    ("minga/agent/providers/native.ex", "minga_agent/providers/native.ex"),
    ("minga/agent/providers/pi_rpc.ex", "minga_agent/providers/pi_rpc.ex"),
    # Messages / events / state
    ("minga/agent/message.ex",          "minga_agent/message.ex"),
    ("minga/agent/event.ex",            "minga_agent/event.ex"),  # Note: NOT events.ex
    ("minga/agent/internal_state.ex",   "minga_agent/internal_state.ex"),
    # Accounting / cost
    ("minga/agent/compaction.ex",       "minga_agent/compaction.ex"),
    ("minga/agent/cost_calculator.ex",  "minga_agent/cost_calculator.ex"),
    ("minga/agent/token_estimator.ex",  "minga_agent/token_estimator.ex"),
    ("minga/agent/turn_usage.ex",       "minga_agent/turn_usage.ex"),
    # Session persistence
    ("minga/agent/memory.ex",           "minga_agent/memory.ex"),
    ("minga/agent/session_store.ex",    "minga_agent/session_store.ex"),
    ("minga/agent/session_export.ex",   "minga_agent/session_export.ex"),
    ("minga/agent/session_metadata.ex", "minga_agent/session_metadata.ex"),
    # Config / credentials / model info
    ("minga/agent/config.ex",           "minga_agent/config.ex"),
    ("minga/agent/credentials.ex",      "minga_agent/credentials.ex"),
    ("minga/agent/model_catalog.ex",    "minga_agent/model_catalog.ex"),
    ("minga/agent/model_limits.ex",     "minga_agent/model_limits.ex"),
    # Utility
    ("minga/agent/retry.ex",            "minga_agent/retry.ex"),
    ("minga/agent/notifier.ex",         "minga_agent/notifier.ex"),
    ("minga/agent/branch.ex",           "minga_agent/branch.ex"),
    ("minga/agent/instruction.ex",      "minga_agent/instruction.ex"),
    ("minga/agent/instructions.ex",     "minga_agent/instructions.ex"),
    ("minga/agent/skills.ex",           "minga_agent/skills.ex"),
    # Data structures
    ("minga/agent/todo_item.ex",        "minga_agent/todo_item.ex"),
    ("minga/agent/context_artifact.ex", "minga_agent/context_artifact.ex"),
    ("minga/agent/file_mention.ex",     "minga_agent/file_mention.ex"),
    ("minga/agent/markdown.ex",         "minga_agent/markdown.ex"),
    ("minga/agent/tool_call.ex",        "minga_agent/tool_call.ex"),
    ("minga/agent/tool_approval.ex",    "minga_agent/tool_approval.ex"),
    # Tools entry point + all tool modules
    ("minga/agent/tools.ex",            "minga_agent/tools.ex"),
    ("minga/agent/tools/diagnostic_feedback.ex", "minga_agent/tools/diagnostic_feedback.ex"),
    ("minga/agent/tools/edit_file.ex",  "minga_agent/tools/edit_file.ex"),
    ("minga/agent/tools/find.ex",       "minga_agent/tools/find.ex"),
    ("minga/agent/tools/git.ex",        "minga_agent/tools/git.ex"),
    ("minga/agent/tools/grep.ex",       "minga_agent/tools/grep.ex"),
    ("minga/agent/tools/list_directory.ex", "minga_agent/tools/list_directory.ex"),
    ("minga/agent/tools/lsp_bridge.ex", "minga_agent/tools/lsp_bridge.ex"),
    ("minga/agent/tools/lsp_code_actions.ex", "minga_agent/tools/lsp_code_actions.ex"),
    ("minga/agent/tools/lsp_definition.ex", "minga_agent/tools/lsp_definition.ex"),
    ("minga/agent/tools/lsp_diagnostics.ex", "minga_agent/tools/lsp_diagnostics.ex"),
    ("minga/agent/tools/lsp_document_symbols.ex", "minga_agent/tools/lsp_document_symbols.ex"),
    ("minga/agent/tools/lsp_hover.ex",  "minga_agent/tools/lsp_hover.ex"),
    ("minga/agent/tools/lsp_references.ex", "minga_agent/tools/lsp_references.ex"),
    ("minga/agent/tools/lsp_rename.ex", "minga_agent/tools/lsp_rename.ex"),
    ("minga/agent/tools/lsp_workspace_symbols.ex", "minga_agent/tools/lsp_workspace_symbols.ex"),
    ("minga/agent/tools/memory_write.ex", "minga_agent/tools/memory_write.ex"),
    ("minga/agent/tools/multi_edit_file.ex", "minga_agent/tools/multi_edit_file.ex"),
    ("minga/agent/tools/notebook.ex",   "minga_agent/tools/notebook.ex"),
    ("minga/agent/tools/read_file.ex",  "minga_agent/tools/read_file.ex"),
    ("minga/agent/tools/shell.ex",      "minga_agent/tools/shell.ex"),
    ("minga/agent/tools/subagent.ex",   "minga_agent/tools/subagent.ex"),
    ("minga/agent/tools/todo.ex",       "minga_agent/tools/todo.ex"),
    ("minga/agent/tools/write_file.ex", "minga_agent/tools/write_file.ex"),
]

# ── Test files to move ────────────────────────────────────────────────────────
# Maps src (relative to test/) -> dst (relative to test/)
TEST_FILES_TO_MOVE = [
    # Note: some test files test presentation modules and stay.
    # Only move tests for domain modules.
    ("minga/agent/branch_test.exs",           "minga_agent/branch_test.exs"),
    ("minga/agent/compaction_test.exs",       "minga_agent/compaction_test.exs"),
    ("minga/agent/config_test.exs",           "minga_agent/config_test.exs"),
    ("minga/agent/context_artifact_test.exs", "minga_agent/context_artifact_test.exs"),
    ("minga/agent/cost_calculator_test.exs",  "minga_agent/cost_calculator_test.exs"),
    ("minga/agent/credentials_test.exs",      "minga_agent/credentials_test.exs"),
    ("minga/agent/event_test.exs",            "minga_agent/event_test.exs"),
    ("minga/agent/file_mention_test.exs",     "minga_agent/file_mention_test.exs"),
    ("minga/agent/instructions_test.exs",     "minga_agent/instructions_test.exs"),
    ("minga/agent/internal_state_test.exs",   "minga_agent/internal_state_test.exs"),
    ("minga/agent/markdown_test.exs",         "minga_agent/markdown_test.exs"),
    ("minga/agent/memory_test.exs",           "minga_agent/memory_test.exs"),
    ("minga/agent/message_test.exs",          "minga_agent/message_test.exs"),
    ("minga/agent/model_catalog_test.exs",    "minga_agent/model_catalog_test.exs"),
    ("minga/agent/model_limits_test.exs",     "minga_agent/model_limits_test.exs"),
    ("minga/agent/notifier_test.exs",         "minga_agent/notifier_test.exs"),
    ("minga/agent/provider_resolver_test.exs","minga_agent/provider_resolver_test.exs"),
    ("minga/agent/providers/native_test.exs", "minga_agent/providers/native_test.exs"),
    ("minga/agent/providers/pi_rpc_test.exs", "minga_agent/providers/pi_rpc_test.exs"),
    ("minga/agent/retry_test.exs",            "minga_agent/retry_test.exs"),
    ("minga/agent/session_export_test.exs",   "minga_agent/session_export_test.exs"),
    ("minga/agent/session_store_test.exs",    "minga_agent/session_store_test.exs"),
    ("minga/agent/session_test.exs",          "minga_agent/session_test.exs"),
    ("minga/agent/skills_test.exs",           "minga_agent/skills_test.exs"),
    ("minga/agent/token_estimator_test.exs",  "minga_agent/token_estimator_test.exs"),
    ("minga/agent/tool_call_test.exs",        "minga_agent/tool_call_test.exs"),
    ("minga/agent/tools_test.exs",            "minga_agent/tools_test.exs"),
    ("minga/agent/turn_usage_test.exs",       "minga_agent/turn_usage_test.exs"),
    # Tools tests
    ("minga/agent/tools/diagnostic_feedback_test.exs", "minga_agent/tools/diagnostic_feedback_test.exs"),
    ("minga/agent/tools/edit_file_test.exs",  "minga_agent/tools/edit_file_test.exs"),
    ("minga/agent/tools/find_test.exs",       "minga_agent/tools/find_test.exs"),
    ("minga/agent/tools/git_test.exs",        "minga_agent/tools/git_test.exs"),
    ("minga/agent/tools/grep_test.exs",       "minga_agent/tools/grep_test.exs"),
    ("minga/agent/tools/list_directory_test.exs", "minga_agent/tools/list_directory_test.exs"),
    ("minga/agent/tools/lsp_bridge_test.exs", "minga_agent/tools/lsp_bridge_test.exs"),
    ("minga/agent/tools/lsp_code_actions_test.exs", "minga_agent/tools/lsp_code_actions_test.exs"),
    ("minga/agent/tools/lsp_definition_test.exs", "minga_agent/tools/lsp_definition_test.exs"),
    ("minga/agent/tools/lsp_diagnostics_test.exs", "minga_agent/tools/lsp_diagnostics_test.exs"),
    ("minga/agent/tools/lsp_document_symbols_test.exs", "minga_agent/tools/lsp_document_symbols_test.exs"),
    ("minga/agent/tools/lsp_hover_test.exs",  "minga_agent/tools/lsp_hover_test.exs"),
    ("minga/agent/tools/lsp_references_test.exs", "minga_agent/tools/lsp_references_test.exs"),
    ("minga/agent/tools/lsp_rename_test.exs", "minga_agent/tools/lsp_rename_test.exs"),
    ("minga/agent/tools/lsp_workspace_symbols_test.exs", "minga_agent/tools/lsp_workspace_symbols_test.exs"),
    ("minga/agent/tools/multi_edit_file_test.exs", "minga_agent/tools/multi_edit_file_test.exs"),
    ("minga/agent/tools/read_file_test.exs",  "minga_agent/tools/read_file_test.exs"),
    ("minga/agent/tools/shell_test.exs",      "minga_agent/tools/shell_test.exs"),
    ("minga/agent/tools/write_file_test.exs", "minga_agent/tools/write_file_test.exs"),
]

# ── Module rename map ─────────────────────────────────────────────────────────
# Old module name -> new module name
# IMPORTANT: ordered longest-first to avoid partial matches during sed.
MODULE_RENAMES = [
    ("Minga.Agent.ProviderResolver",   "MingaAgent.ProviderResolver"),
    ("Minga.Agent.ContextArtifact",    "MingaAgent.ContextArtifact"),
    ("Minga.Agent.SessionMetadata",    "MingaAgent.SessionMetadata"),
    ("Minga.Agent.SessionExport",      "MingaAgent.SessionExport"),
    ("Minga.Agent.SessionStore",       "MingaAgent.SessionStore"),
    ("Minga.Agent.CostCalculator",     "MingaAgent.CostCalculator"),
    ("Minga.Agent.ModelCatalog",       "MingaAgent.ModelCatalog"),
    ("Minga.Agent.TokenEstimator",     "MingaAgent.TokenEstimator"),
    ("Minga.Agent.InternalState",      "MingaAgent.InternalState"),
    ("Minga.Agent.Providers.Native",   "MingaAgent.Providers.Native"),
    ("Minga.Agent.Providers.PiRpc",    "MingaAgent.Providers.PiRpc"),
    ("Minga.Agent.ToolApproval",       "MingaAgent.ToolApproval"),
    ("Minga.Agent.FileMention",        "MingaAgent.FileMention"),
    ("Minga.Agent.ModelLimits",        "MingaAgent.ModelLimits"),
    ("Minga.Agent.Compaction",         "MingaAgent.Compaction"),
    ("Minga.Agent.Credentials",        "MingaAgent.Credentials"),
    ("Minga.Agent.Instructions",       "MingaAgent.Instructions"),
    ("Minga.Agent.Instruction",        "MingaAgent.Instruction"),
    ("Minga.Agent.Supervisor",         "MingaAgent.Supervisor"),
    ("Minga.Agent.TurnUsage",          "MingaAgent.TurnUsage"),
    ("Minga.Agent.ToolCall",           "MingaAgent.ToolCall"),
    ("Minga.Agent.Markdown",           "MingaAgent.Markdown"),
    ("Minga.Agent.Notifier",           "MingaAgent.Notifier"),
    ("Minga.Agent.Session",            "MingaAgent.Session"),
    ("Minga.Agent.Message",            "MingaAgent.Message"),
    ("Minga.Agent.Memory",             "MingaAgent.Memory"),
    ("Minga.Agent.Provider",           "MingaAgent.Provider"),
    ("Minga.Agent.Skills",             "MingaAgent.Skills"),
    ("Minga.Agent.Branch",             "MingaAgent.Branch"),
    ("Minga.Agent.Config",             "MingaAgent.Config"),
    ("Minga.Agent.TodoItem",           "MingaAgent.TodoItem"),
    ("Minga.Agent.Retry",              "MingaAgent.Retry"),
    # Tools — longest first
    ("Minga.Agent.Tools.DiagnosticFeedback", "MingaAgent.Tools.DiagnosticFeedback"),
    ("Minga.Agent.Tools.LspCodeActions",     "MingaAgent.Tools.LspCodeActions"),
    ("Minga.Agent.Tools.LspDefinition",      "MingaAgent.Tools.LspDefinition"),
    ("Minga.Agent.Tools.LspDiagnostics",     "MingaAgent.Tools.LspDiagnostics"),
    ("Minga.Agent.Tools.LspDocumentSymbols", "MingaAgent.Tools.LspDocumentSymbols"),
    ("Minga.Agent.Tools.LspWorkspaceSymbols","MingaAgent.Tools.LspWorkspaceSymbols"),
    ("Minga.Agent.Tools.LspReferences",      "MingaAgent.Tools.LspReferences"),
    ("Minga.Agent.Tools.LspLspBridge",       "MingaAgent.Tools.LspLspBridge"),
    ("Minga.Agent.Tools.ListDirectory",      "MingaAgent.Tools.ListDirectory"),
    ("Minga.Agent.Tools.MultiEditFile",      "MingaAgent.Tools.MultiEditFile"),
    ("Minga.Agent.Tools.MemoryWrite",        "MingaAgent.Tools.MemoryWrite"),
    ("Minga.Agent.Tools.LspHover",           "MingaAgent.Tools.LspHover"),
    ("Minga.Agent.Tools.LspRename",          "MingaAgent.Tools.LspRename"),
    ("Minga.Agent.Tools.LspBridge",          "MingaAgent.Tools.LspBridge"),
    ("Minga.Agent.Tools.EditFile",           "MingaAgent.Tools.EditFile"),
    ("Minga.Agent.Tools.ReadFile",           "MingaAgent.Tools.ReadFile"),
    ("Minga.Agent.Tools.WriteFile",          "MingaAgent.Tools.WriteFile"),
    ("Minga.Agent.Tools.Subagent",           "MingaAgent.Tools.Subagent"),
    ("Minga.Agent.Tools.Notebook",           "MingaAgent.Tools.Notebook"),
    ("Minga.Agent.Tools.Shell",              "MingaAgent.Tools.Shell"),
    ("Minga.Agent.Tools.Grep",               "MingaAgent.Tools.Grep"),
    ("Minga.Agent.Tools.Find",               "MingaAgent.Tools.Find"),
    ("Minga.Agent.Tools.Todo",               "MingaAgent.Tools.Todo"),
    ("Minga.Agent.Tools.Git",                "MingaAgent.Tools.Git"),
    # Tools entry point (after all sub-modules)
    ("Minga.Agent.Tools",              "MingaAgent.Tools"),
    # Event struct (NOT Events which stays)
    ("Minga.Agent.Event",              "MingaAgent.Event"),
]


def run(cmd, cwd=None, check=True):
    print(f"  $ {cmd}")
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout.rstrip())
    if result.stderr:
        print(result.stderr.rstrip(), file=sys.stderr)
    if check and result.returncode != 0:
        print(f"ERROR: command failed with code {result.returncode}", file=sys.stderr)
        sys.exit(1)
    return result


def make_dirs(base, path):
    dir_path = os.path.join(base, os.path.dirname(path))
    os.makedirs(dir_path, exist_ok=True)


def move_file(base, src, dst):
    src_full = os.path.join(base, src)
    dst_full = os.path.join(base, dst)
    if not os.path.exists(src_full):
        print(f"  WARNING: source not found, skipping: {src_full}")
        return False
    make_dirs(base, dst)
    run(f"git mv {src_full} {dst_full}", cwd=base)
    return True


def replace_in_file(path, old, new):
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
    except (IOError, UnicodeDecodeError):
        return False

    # Use word-boundary aware replacement: module name must be followed by
    # a non-identifier character (dot, comma, space, newline, parens, etc.)
    pattern = re.escape(old) + r'(?=[^a-zA-Z0-9_]|$)'
    new_content = re.sub(pattern, new, content)
    if new_content != content:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
        return True
    return False


def replace_in_all_files(base, old, new, extensions=(".ex", ".exs")):
    changed = []
    for root, dirs, files in os.walk(base):
        # Skip _build and deps
        dirs[:] = [d for d in dirs if d not in ("_build", "deps", ".git", "vendor")]
        for fname in files:
            if any(fname.endswith(ext) for ext in extensions):
                path = os.path.join(root, fname)
                if replace_in_file(path, old, new):
                    changed.append(path)
    return changed


def main():
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    print(f"Working directory: {base}")

    # ── Step 1: Create destination directories ────────────────────────────────
    print("\n=== Step 1: Creating lib/minga_agent/ directories ===")
    for _, dst in FILES_TO_MOVE:
        make_dirs(os.path.join(base, "lib"), dst)
    print("  Done.")

    # ── Step 2: Move lib files ────────────────────────────────────────────────
    print("\n=== Step 2: Moving lib source files ===")
    moved = 0
    for src, dst in FILES_TO_MOVE:
        if move_file(os.path.join(base, "lib"), src, dst):
            moved += 1
    print(f"  Moved {moved} lib files.")

    # ── Step 3: Move test files ───────────────────────────────────────────────
    print("\n=== Step 3: Moving test files ===")
    moved_tests = 0
    for src, dst in TEST_FILES_TO_MOVE:
        # Only move if source exists (some test files may not exist)
        src_full = os.path.join(base, "test", src)
        dst_full = os.path.join(base, "test", dst)
        if os.path.exists(src_full):
            make_dirs(os.path.join(base, "test"), dst)
            run(f"git mv {src_full} {dst_full}", cwd=base)
            moved_tests += 1
        else:
            print(f"  WARNING: test file not found: {src}")
    print(f"  Moved {moved_tests} test files.")

    # ── Step 4: Apply module renames across all files ─────────────────────────
    print("\n=== Step 4: Renaming module references ===")
    total_changed_files = set()
    for old, new in MODULE_RENAMES:
        changed = replace_in_all_files(base, old, new)
        if changed:
            total_changed_files.update(changed)
            print(f"  {old} -> {new}: {len(changed)} file(s) changed")

    print(f"\n  Total files with reference updates: {len(total_changed_files)}")

    # ── Step 5: Also replace in mix.exs and config files ─────────────────────
    print("\n=== Step 5: Updating mix.exs and config files ===")
    extra_files = [
        os.path.join(base, "mix.exs"),
    ]
    for cfg in ["config.exs", "dev.exs", "test.exs", "runtime.exs", "prod.exs"]:
        p = os.path.join(base, "config", cfg)
        if os.path.exists(p):
            extra_files.append(p)
    for path in extra_files:
        if os.path.exists(path):
            changed_any = False
            for old, new in MODULE_RENAMES:
                if replace_in_file(path, old, new):
                    changed_any = True
            if changed_any:
                print(f"  Updated: {os.path.relpath(path, base)}")

    print("\n=== Migration complete ===")
    print("Next: run `mix compile --warnings-as-errors` to catch missed references.")


if __name__ == "__main__":
    main()
