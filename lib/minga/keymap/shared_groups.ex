defmodule Minga.Keymap.SharedGroups do
  @moduledoc """
  Named binding groups that scopes can include.

  Each group is a function returning a list of `{key_sequence, command, description}`
  tuples. Scopes call `Bindings.merge_bindings/2` (or `/3` with exclusions) to fold
  a group's bindings into their trie at build time. Scope-specific bindings applied
  after the merge override group bindings on conflict.

  ## Design

  Groups are pure data, not tied to any scope. A group doesn't know which scopes
  include it. This keeps the dependency direction clean: scopes depend on groups,
  never the reverse.

  Groups use `~k` for readable key tuples when the key is part of the standard parser token set. Raw tuples remain only for frontend-specific keys that do not have human-readable parser tokens.

  ## Adding a new group

  1. Define a function that returns `[{[key()], command_atom, description}]`
  2. Add the group name to `@group_names`
  3. Include it in the relevant scope modules via `Bindings.merge_bindings/2`
  """

  alias Minga.Keymap.Bindings

  import Bitwise
  import Minga.Keymap.Sigil

  # Modifier bitmasks (same as used in scope modules)
  @shift 0x01
  @alt 0x04

  # Special codepoints
  @enter 13

  # Arrow keys (Kitty protocol)
  @arrow_up 57_352
  @arrow_down 57_353

  # Arrow keys (macOS legacy)
  @arrow_up_mac 0xF700
  @arrow_down_mac 0xF701

  @typedoc "A binding tuple: `{key_sequence, command, description}`."
  @type binding :: {[Bindings.key()], atom(), String.t()}

  @typedoc "A named group identifier."
  @type group_name ::
          :ctrl_agent_common
          | :cua_navigation
          | :cua_cmd_chords
          | :newline_variants

  @doc "All known group names."
  @spec group_names() :: [group_name()]
  def group_names do
    [
      :ctrl_agent_common,
      :cua_navigation,
      :cua_cmd_chords,
      :newline_variants
    ]
  end

  @doc """
  Returns bindings for a named group.

  Raises `ArgumentError` if the group name is not recognized.
  """
  @spec get(group_name()) :: [binding()]
  def get(:ctrl_agent_common), do: ctrl_agent_common()
  def get(:cua_navigation), do: cua_navigation()
  def get(:cua_cmd_chords), do: cua_cmd_chords()
  def get(:newline_variants), do: newline_variants()

  def get(name) do
    raise ArgumentError, "unknown shared group: #{inspect(name)}"
  end

  # ── Group definitions ──────────────────────────────────────────────────────

  @doc """
  Ctrl shortcuts shared across agent vim states (insert and input_normal).

  These are agent-domain commands that use Ctrl modifiers. They're shared
  between insert mode and input_normal mode within the agent scope. Not
  shared with the editor scope (the editor has its own Ctrl handling via
  the Mode FSM).
  """
  @spec ctrl_agent_common() :: [binding()]
  def ctrl_agent_common do
    [
      {~k(C-c), :agent_ctrl_c, "Abort (streaming) or normal mode (idle)"},
      {~k(C-d), :agent_scroll_half_down, "Scroll down"},
      {~k(C-u), :agent_scroll_half_up, "Scroll up"},
      {~k(C-l), :agent_clear_chat, "Clear chat display"},
      {~k(C-s), :agent_save_buffer, "Save buffer"},
      {~k(C-q), :agent_unfocus_and_quit, "Unfocus and quit"}
    ]
  end

  @doc """
  CUA arrow key navigation bindings.

  Both Kitty protocol and macOS legacy codepoints are included so the
  bindings work across all terminal emulators and the native GUI.
  Used by file_tree, git_status, and agent CUA modes.
  """
  @spec cua_navigation() :: [binding()]
  def cua_navigation do
    [
      # Up/down navigation (both encodings)
      {[{@arrow_up, 0}], :move_up, "Move up"},
      {[{@arrow_down, 0}], :move_down, "Move down"},
      {[{@arrow_up_mac, 0}], :move_up, "Move up"},
      {[{@arrow_down_mac, 0}], :move_down, "Move down"},
      # Page scroll
      {[{@arrow_up, @shift}], :half_page_up, "Half page up"},
      {[{@arrow_down, @shift}], :half_page_down, "Half page down"},
      {[{@arrow_up_mac, @shift}], :half_page_up, "Half page up"},
      {[{@arrow_down_mac, @shift}], :half_page_down, "Half page down"}
    ]
  end

  @doc """
  CUA Cmd/Ctrl command chords (copy, undo, redo, paste, select-all, save).

  Cmd variants are included for GUI surfaces. Ctrl fallbacks cover the TUI,
  except Ctrl+S, which stays on the global save handler so saves keep the
  normal command lifecycle.
  """
  @spec cua_cmd_chords() :: [binding()]
  def cua_cmd_chords do
    cmd = 0x08

    [
      # GUI (Cmd) bindings
      {[{?c, cmd}], :yank_visual_selection, "Copy"},
      {[{?x, cmd}], :delete_visual_selection, "Cut"},
      {[{?v, cmd}], :paste_after, "Paste"},
      {[{?z, cmd}], :undo, "Undo"},
      {[{?z, cmd ||| @shift}], :redo, "Redo"},
      {[{?a, cmd}], :select_all, "Select all"},
      {[{?s, cmd}], :save, "Save"},
      # TUI (Ctrl) fallbacks
      {~k(C-c), :copy_or_interrupt, "Copy selection / interrupt"},
      {~k(C-z), :undo, "Undo"},
      {~k(C-y), :redo, "Redo"},
      {~k(C-v), :paste_after, "Paste"},
      {~k(C-a), :select_all, "Select all"}
    ]
  end

  @doc """
  Multi-encoding newline insertion bindings.

  Shift+Enter produces different byte sequences depending on the terminal
  and protocol. These four bindings cover all known encodings:

  1. `{Enter, shift}` - Kitty protocol (CSI 13;2 u)
  2. `{Ctrl+J, 0}` - Ghostty/macOS (LF = Ctrl+J in Kitty protocol)
  3. `{0x0A, 0}` - Legacy terminals (raw LF)
  4. `{Enter, alt}` - Universal fallback (Alt+Enter works everywhere)
  """
  @spec newline_variants() :: [binding()]
  def newline_variants do
    [
      {[{@enter, @shift}], :agent_insert_newline, "Insert newline"},
      {~k(C-j), :agent_insert_newline, "Insert newline"},
      {[{0x0A, 0}], :agent_insert_newline, "Insert newline"},
      {[{@enter, @alt}], :agent_insert_newline, "Insert newline"}
    ]
  end
end
