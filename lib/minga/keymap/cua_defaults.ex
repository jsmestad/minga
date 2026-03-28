defmodule Minga.Keymap.CUADefaults do
  @moduledoc """
  Shared CUA keybinding fragments for scope modules.

  Provides composable trie builders for standard CUA vocabulary:
  arrow-key navigation, Cmd-chord clipboard/undo, and common editing
  primitives (Enter, Backspace, Tab, Escape). Scope modules merge
  these fragments with their surface-specific bindings to build the
  `:cua` keymap clause.

  All functions return `Bindings.node_t()` suitable for piping into
  additional `Bindings.bind/4` calls.
  """

  alias Minga.Keymap.Bindings

  # Modifier bitmask (used by interrupt_trie)
  @ctrl 0x02

  # Common keys (still used by editing_trie and horizontal_nav_trie)
  @arrow_left 57_350
  @arrow_right 57_351
  @ns_left 0xF702
  @ns_right 0xF703
  @escape 27
  @backspace 127
  @tab 9

  @doc """
  Arrow key navigation bindings.

  Up/Down map to vertical movement commands. Accepts both Kitty protocol
  and macOS NSEvent codepoints so bindings work on both TUI and GUI.
  """
  @spec navigation_trie() :: Bindings.node_t()
  def navigation_trie do
    Bindings.merge_group(Bindings.new(), :cua_navigation)
  end

  @doc """
  Cmd-chord bindings for clipboard, undo, and common actions.

  Cmd+C = copy, Cmd+X = cut, Cmd+V = paste, Cmd+Z = undo,
  Cmd+Shift+Z = redo, Cmd+A = select all, Cmd+S = save.

  Also includes Ctrl fallbacks for TUI where terminals intercept
  Cmd+key at the OS level. Ctrl+Z = undo, Ctrl+Y = redo,
  Ctrl+V = paste, Ctrl+A = select all.

  Note: Ctrl+C is NOT bound to copy here. It stays as interrupt
  (see `interrupt_trie/0`). Selection-aware copy via Ctrl+C is
  handled by the Interrupt handler which checks for active selection.
  """
  @spec cmd_chords_trie() :: Bindings.node_t()
  def cmd_chords_trie do
    Bindings.merge_group(Bindings.new(), :cua_cmd_chords)
  end

  @doc """
  Common editing primitives: Escape, Enter, Backspace.

  These are surface-neutral defaults. Scopes override specific keys
  when needed (e.g., Enter opens a file in file tree, submits in agent).
  """
  @spec editing_trie() :: Bindings.node_t()
  def editing_trie do
    Bindings.new()
    |> Bindings.bind([{@escape, 0}], :escape, "Cancel / dismiss")
    |> Bindings.bind([{@backspace, 0}], :delete_before, "Delete before cursor")
    |> Bindings.bind([{@tab, 0}], :indent, "Indent / next field")
  end

  @doc """
  Left/Right arrow keys for horizontal navigation.

  Used by file tree (expand/collapse) and other surfaces that need
  directional input.
  """
  @spec horizontal_nav_trie() :: Bindings.node_t()
  def horizontal_nav_trie do
    Bindings.new()
    |> Bindings.bind([{@arrow_left, 0}], :move_left, "Move left")
    |> Bindings.bind([{@arrow_right, 0}], :move_right, "Move right")
    |> Bindings.bind([{@ns_left, 0}], :move_left, "Move left")
    |> Bindings.bind([{@ns_right, 0}], :move_right, "Move right")
  end

  @doc """
  Ctrl+C interrupt binding. Shared across all CUA surfaces.
  """
  @spec interrupt_trie() :: Bindings.node_t()
  def interrupt_trie do
    Bindings.new()
    |> Bindings.bind([{?c, @ctrl}], :interrupt, "Interrupt / cancel")
  end
end
