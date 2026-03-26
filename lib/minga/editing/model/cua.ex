defmodule Minga.Editing.Model.CUA do
  @moduledoc """
  CUA (Common User Access) editing model implementation.

  Standard macOS-style editing: always in insert mode, Shift+arrow
  selection, Cmd chord bindings for clipboard and undo. No modal
  mode switching. The cursor is always a beam.

  ## State

  The CUA editing model state tracks:
  - `selection`: nil when no selection, or `%{anchor: {line, col}}` when
    a shift-selection is active. The cursor position is the other end of
    the selection range.

  ## Key mapping

  CUA translates keys to the same command atoms that vim produces.
  Arrow keys become `:move_left`, `:move_right`, etc. Shift+arrows
  become `{:extend_selection, :left}`, etc. Printable characters become
  `{:insert_char, char}`. This means the entire command execution layer
  (Commands module, buffer operations, register management) works
  unchanged.

  ## How it differs from Vim

  - `mode/1` always returns `:cua`
  - `inserting?/1` always returns `true`
  - `selecting?/1` returns true when a shift-selection anchor is active
  - `cursor_shape/1` always returns `:beam`
  - No operator-pending, no leader keys, no count prefixes
  - Key dispatch is handled by `Input.CUA.Dispatch` instead of `Input.ModeFSM`
  """

  @behaviour Minga.Editing.Model

  # ── State ──────────────────────────────────────────────────────────────────

  @typedoc "Selection anchor for shift-select. nil means no selection."
  @type selection :: %{anchor: {non_neg_integer(), non_neg_integer()}} | nil

  @typedoc "CUA editing model state."
  @type t :: %__MODULE__{
          selection: selection()
        }

  defstruct selection: nil

  # ── EditingModel callbacks ─────────────────────────────────────────────────

  @impl Minga.Editing.Model
  @spec process_key(t(), Minga.Editing.Model.key()) ::
          {Minga.Editing.Model.mode_label(), [Minga.Editing.Model.command()], t()}
  def process_key(%__MODULE__{} = state, {codepoint, modifiers}) do
    {commands, new_state} = dispatch_key(state, codepoint, modifiers)
    {:cua, commands, new_state}
  end

  @impl Minga.Editing.Model
  @spec initial_state() :: t()
  def initial_state, do: %__MODULE__{}

  @impl Minga.Editing.Model
  @spec mode_display(t()) :: String.t()
  def mode_display(%__MODULE__{}), do: ""

  @impl Minga.Editing.Model
  @spec mode(t()) :: Minga.Editing.Model.mode_label()
  def mode(%__MODULE__{}), do: :cua

  @impl Minga.Editing.Model
  @spec inserting?(t()) :: boolean()
  def inserting?(%__MODULE__{}), do: true

  @impl Minga.Editing.Model
  @spec selecting?(t()) :: boolean()
  def selecting?(%__MODULE__{selection: nil}), do: false
  def selecting?(%__MODULE__{selection: _}), do: true

  @impl Minga.Editing.Model
  @spec cursor_shape(t()) :: :beam | :block | :underline
  def cursor_shape(%__MODULE__{}), do: :beam

  @impl Minga.Editing.Model
  @spec key_sequence_pending?(t()) :: boolean()
  def key_sequence_pending?(%__MODULE__{}), do: false

  @impl Minga.Editing.Model
  @spec status_segment(t()) :: String.t()
  def status_segment(%__MODULE__{}), do: ""

  # ── Convenience ────────────────────────────────────────────────────────────

  @doc "Creates a CUA state from editor state fields. Currently a no-op wrapper."
  @spec from_editor() :: t()
  def from_editor, do: %__MODULE__{}

  # ── Key dispatch ───────────────────────────────────────────────────────────
  #
  # Modifier bit flags (matching the port protocol):
  #   bit 0 (1)  = Shift
  #   bit 1 (2)  = Alt/Option
  #   bit 2 (4)  = Ctrl
  #   bit 3 (8)  = Super/Cmd
  #
  # Special codepoints (matching libvaxis / port protocol encoding):
  #   0xF700 = Up, 0xF701 = Down, 0xF702 = Left, 0xF703 = Right
  #   0x08 or 0x7F = Backspace, 0xF728 = Forward Delete
  #   0x0D = Enter/Return, 0x1B = Escape, 0x09 = Tab

  @shift 1
  @ctrl 4
  @cmd 8

  @up 0xF700
  @down 0xF701
  @left 0xF702
  @right 0xF703
  @backspace_bs 0x08
  @backspace_del 0x7F
  @forward_delete 0xF728
  @enter 0x0D
  @escape 0x1B
  @tab 0x09
  @home 0xF729
  @end_key 0xF72B

  @spec dispatch_key(t(), non_neg_integer(), non_neg_integer()) ::
          {[Minga.Editing.Model.command()], t()}

  # ── Cmd chords ───────────────────────────────────────────────────────────

  # Cmd+Z = undo
  defp dispatch_key(state, ?z, mods) when Bitwise.band(mods, @cmd) != 0 do
    if Bitwise.band(mods, @shift) != 0 do
      {[:redo], clear_selection(state)}
    else
      {[:undo], clear_selection(state)}
    end
  end

  # Cmd+A = select all
  defp dispatch_key(state, ?a, mods) when Bitwise.band(mods, @cmd) != 0 do
    {[:select_all], state}
  end

  # Cmd+C = copy
  defp dispatch_key(state, ?c, mods) when Bitwise.band(mods, @cmd) != 0 do
    {[:yank_visual_selection], state}
  end

  # Cmd+X = cut
  defp dispatch_key(state, ?x, mods) when Bitwise.band(mods, @cmd) != 0 do
    {[:delete_visual_selection], clear_selection(state)}
  end

  # Cmd+E = use selection for find (write to Find Pasteboard)
  defp dispatch_key(state, ?e, mods) when Bitwise.band(mods, @cmd) != 0 do
    {[:use_selection_for_find], state}
  end

  # Cmd+G = find next, Cmd+Shift+G = find previous
  # (on GUI, Swift intercepts these and reads Find Pasteboard directly;
  # this is the fallback for TUI or when Swift doesn't intercept)
  defp dispatch_key(state, ?g, mods) when Bitwise.band(mods, @cmd) != 0 do
    if Bitwise.band(mods, @shift) != 0 do
      {[:search_prev], state}
    else
      {[:search_next], state}
    end
  end

  # Cmd+V = paste
  defp dispatch_key(state, ?v, mods) when Bitwise.band(mods, @cmd) != 0 do
    {[:paste_after], clear_selection(state)}
  end

  # Cmd+S = save
  defp dispatch_key(state, ?s, mods) when Bitwise.band(mods, @cmd) != 0 do
    {[:save], state}
  end

  # ── Arrow keys ───────────────────────────────────────────────────────────

  # Shift+arrows = extend selection
  defp dispatch_key(state, @up, mods) when Bitwise.band(mods, @shift) != 0 do
    {[{:extend_selection, :up}], maybe_start_selection(state)}
  end

  defp dispatch_key(state, @down, mods) when Bitwise.band(mods, @shift) != 0 do
    {[{:extend_selection, :down}], maybe_start_selection(state)}
  end

  defp dispatch_key(state, @left, mods) when Bitwise.band(mods, @shift) != 0 do
    {[{:extend_selection, :left}], maybe_start_selection(state)}
  end

  defp dispatch_key(state, @right, mods) when Bitwise.band(mods, @shift) != 0 do
    {[{:extend_selection, :right}], maybe_start_selection(state)}
  end

  # Plain arrows = movement (clear selection)
  defp dispatch_key(state, @up, _mods), do: {[:move_up], clear_selection(state)}
  defp dispatch_key(state, @down, _mods), do: {[:move_down], clear_selection(state)}
  defp dispatch_key(state, @left, _mods), do: {[:move_left], clear_selection(state)}
  defp dispatch_key(state, @right, _mods), do: {[:move_right], clear_selection(state)}

  # Home/End
  defp dispatch_key(state, @home, mods) when Bitwise.band(mods, @shift) != 0 do
    {[{:extend_selection, :line_start}], maybe_start_selection(state)}
  end

  defp dispatch_key(state, @end_key, mods) when Bitwise.band(mods, @shift) != 0 do
    {[{:extend_selection, :line_end}], maybe_start_selection(state)}
  end

  defp dispatch_key(state, @home, _mods), do: {[:first_non_blank], clear_selection(state)}
  defp dispatch_key(state, @end_key, _mods), do: {[:line_end], clear_selection(state)}

  # ── Editing keys ─────────────────────────────────────────────────────────

  # Backspace
  defp dispatch_key(%{selection: sel} = state, cp, _mods)
       when cp in [@backspace_bs, @backspace_del] and sel != nil do
    {[:delete_visual_selection], clear_selection(state)}
  end

  defp dispatch_key(state, cp, _mods)
       when cp in [@backspace_bs, @backspace_del] do
    {[:delete_before], state}
  end

  # Forward delete
  defp dispatch_key(%{selection: sel} = state, @forward_delete, _mods) when sel != nil do
    {[:delete_visual_selection], clear_selection(state)}
  end

  defp dispatch_key(state, @forward_delete, _mods), do: {[:delete_at], state}

  # Enter
  defp dispatch_key(state, @enter, _mods) do
    {[{:insert_char, "\n"}], clear_selection(state)}
  end

  # Tab
  defp dispatch_key(state, @tab, _mods) do
    {[:indent_line], state}
  end

  # Escape = clear selection or do nothing
  defp dispatch_key(state, @escape, _mods) do
    {[], clear_selection(state)}
  end

  # Ctrl+keys that should be ignored (let overlays handle them)
  defp dispatch_key(state, _cp, mods) when Bitwise.band(mods, @ctrl) != 0 do
    {[], state}
  end

  # ── Printable characters ─────────────────────────────────────────────────

  defp dispatch_key(%{selection: sel} = state, codepoint, _mods)
       when sel != nil and codepoint >= 0x20 do
    # Replace selection with typed character
    char = <<codepoint::utf8>>
    {[:delete_visual_selection, {:insert_char, char}], clear_selection(state)}
  end

  defp dispatch_key(state, codepoint, _mods) when codepoint >= 0x20 do
    char = <<codepoint::utf8>>
    {[{:insert_char, char}], state}
  end

  # Fallback: unknown key, ignore
  defp dispatch_key(state, _codepoint, _mods), do: {[], state}

  # ── Selection helpers ────────────────────────────────────────────────────

  @spec clear_selection(t()) :: t()
  defp clear_selection(%__MODULE__{} = state), do: %{state | selection: nil}

  @spec maybe_start_selection(t()) :: t()
  defp maybe_start_selection(%__MODULE__{selection: nil} = state) do
    # The actual anchor position will be set by the command executor
    # when it processes the extend_selection command and reads the
    # current cursor position. We just flag that selection is active.
    %{state | selection: %{anchor: {0, 0}}}
  end

  defp maybe_start_selection(state), do: state
end
