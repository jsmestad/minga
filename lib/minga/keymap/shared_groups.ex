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

  Groups use raw `{codepoint, modifiers}` key tuples (not `KeyParser` strings)
  because scope tries are built at module load time and string parsing adds
  unnecessary overhead. Use the constants defined in this module for readability.

  ## Adding a new group

  1. Define a function that returns `[{[key()], command_atom, description}]`
  2. Add the group name to `@group_names`
  3. Include it in the relevant scope modules via `Bindings.merge_bindings/2`
  """

  alias Minga.Keymap.Bindings

  import Bitwise

  # Modifier bitmasks (same as used in scope modules)
  @ctrl 0x02
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
      {[{?c, @ctrl}], :agent_ctrl_c, "Abort (streaming) or normal mode (idle)"},
      {[{?d, @ctrl}], :agent_scroll_half_down, "Scroll down"},
      {[{?u, @ctrl}], :agent_scroll_half_up, "Scroll up"},
      {[{?l, @ctrl}], :agent_clear_chat, "Clear chat display"},
      {[{?s, @ctrl}], :agent_save_buffer, "Save buffer"},
      {[{?q, @ctrl}], :agent_unfocus_and_quit, "Unfocus and quit"}
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
  CUA Cmd/Ctrl command chords (undo, redo, paste, select-all).

  Both Cmd (GUI) and Ctrl (TUI) variants are included. Used by editor
  CUA mode and agent CUA mode.
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
      {[{?z, @ctrl}], :undo, "Undo"},
      {[{?y, @ctrl}], :redo, "Redo"},
      {[{?v, @ctrl}], :paste_after, "Paste"},
      {[{?a, @ctrl}], :select_all, "Select all"}
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
      {[{?j, @ctrl}], :agent_insert_newline, "Insert newline"},
      {[{0x0A, 0}], :agent_insert_newline, "Insert newline"},
      {[{@enter, @alt}], :agent_insert_newline, "Insert newline"}
    ]
  end
end
