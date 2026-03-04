---
description: Git worktree cheatsheet for parallel agent work
---

## Git Worktrees Cheatsheet

A worktree is a second (or third, etc.) working directory linked to the same repo. Each checks out a different branch but shares the same `.git` history.

### Setup

```bash
# Create a worktree on a new branch (most common)
git worktree add ../minga-zig feat/zig-renderer
#                 ^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^
#                 path on disk  branch name

# Create a worktree on an existing branch
git worktree add ../minga-elixir feat/elixir-buffer

# Create from a specific commit
git worktree add ../minga-experiment abc123f
```

### Day-to-Day

```bash
# List all worktrees
git worktree list

# Work in a worktree (it's just a normal directory)
cd ../minga-zig
# edit, build, test — completely independent from main worktree

# Commit and push from within the worktree
git add . && git commit -m "feat: zig renderer" && git push

# Back in main worktree, merge when ready
cd ../minga
git merge feat/zig-renderer
```

### Cleanup

```bash
# Remove a worktree (after merging its branch)
git worktree remove ../minga-zig

# If the directory was already deleted manually
git worktree prune

# Delete the branch too (if merged)
git branch -d feat/zig-renderer
```

### Rules

- Each branch can only be checked out in ONE worktree at a time
- All worktrees share the same `.git` (refs, remotes, config)
- `_build/` and `zig/zig-out/` are per-worktree (separate directories = separate build caches)
- You CAN run `mix test` in one worktree while editing in another

### For Minga Sub-Agents

```bash
# Example: parallel Elixir + Zig work
git worktree add ../minga-zig feat/zig-renderer
git worktree add ../minga-elixir feat/elixir-buffer

# Run sub-agents with cwd pointing to the right worktree
# (the subagent tool supports a `cwd` parameter per task)
```
