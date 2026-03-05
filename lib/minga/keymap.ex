defmodule Minga.Keymap do
  @moduledoc """
  Mode-specific keymap management for Minga.

  Provides a trie-based keymap for each editor mode. Default keybindings
  are defined as data and loaded on demand via `keymap_for/1`.

  ## Modifier constants (bitmask)

  * `0x00` — no modifier
  * `0x01` — Shift
  * `0x02` — Ctrl
  * `0x04` — Alt
  * `0x08` — Super
  """

  alias Minga.Keymap.Bindings

  @typedoc "Supported editor modes."
  @type mode :: :normal | :insert | :visual | :command

  # Modifier bitmasks (mirrors Port.Protocol constants)
  @none 0x00
  @ctrl 0x02

  # ── Default keybinding data ─────────────────────────────────────────────────
  #
  # Format: {[{codepoint, modifiers}], command_atom, description_string}
  # Defined as module attributes so they are pure data with no runtime cost.

  @normal_bindings [
    # Movement
    {[{?h, @none}], :move_left, "Move cursor left"},
    {[{?j, @none}], :move_down, "Move cursor down"},
    {[{?k, @none}], :move_up, "Move cursor up"},
    {[{?l, @none}], :move_right, "Move cursor right"},
    # Deletion
    {[{?x, @none}], :delete_at, "Delete character at cursor"},
    {[{?X, @none}], :delete_before, "Delete character before cursor"},
    # Save / quit
    {[{?Z, @none}, {?Z, @none}], :save, "Save file (ZZ)"},
    {[{?Z, @none}, {?Q, @none}], :force_quit, "Force quit (ZQ)"}
  ]

  @insert_bindings [
    # Ctrl+S → save
    {[{?s, @ctrl}], :save, "Save file"},
    # Ctrl+Q → quit
    {[{?q, @ctrl}], :quit, "Quit editor"}
  ]

  @visual_bindings [
    # Movement (same as normal)
    {[{?h, @none}], :move_left, "Move cursor left"},
    {[{?j, @none}], :move_down, "Move cursor down"},
    {[{?k, @none}], :move_up, "Move cursor up"},
    {[{?l, @none}], :move_right, "Move cursor right"},
    # Operators on selection
    {[{?d, @none}], :delete_selection, "Delete selection"},
    {[{?y, @none}], :yank_selection, "Yank selection"},
    {[{?c, @none}], :change_selection, "Change selection"}
  ]

  @command_bindings []

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Returns the default keymap trie for the given editor mode.

  Each call builds a fresh trie from the static binding data. The result
  can be cached by the caller if needed.
  """
  @spec keymap_for(mode()) :: Bindings.node_t()
  def keymap_for(mode) when mode in [:normal, :insert, :visual, :command] do
    bindings_for(mode)
    |> Enum.reduce(Bindings.new(), fn {keys, command, description}, trie ->
      Bindings.bind(trie, keys, command, description)
    end)
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec bindings_for(mode()) ::
          [{[Bindings.key()], atom(), String.t()}]
  defp bindings_for(:normal), do: @normal_bindings
  defp bindings_for(:insert), do: @insert_bindings
  defp bindings_for(:visual), do: @visual_bindings
  defp bindings_for(:command), do: @command_bindings
end
