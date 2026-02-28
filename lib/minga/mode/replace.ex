defmodule Minga.Mode.Replace do
  @moduledoc """
  Vim Replace mode key handler.

  Replace mode is entered from Normal mode via `R`. Every printable key
  overwrites the character under the cursor (saving the original so that
  Backspace can restore it). Pressing **Escape** returns to Normal mode.

  ## Key bindings

  | Key        | Action                                     |
  |------------|--------------------------------------------|
  | Printable  | Overwrite char at cursor, move forward     |
  | Backspace  | Restore previous character, move backward  |
  | Escape     | Return to Normal mode                      |
  | Arrow keys | Move cursor (without leaving Replace)      |
  """

  @behaviour Minga.Mode

  alias Minga.Mode
  alias Minga.Mode.ReplaceState

  # Special codepoints
  @escape 27

  # Arrow key codepoints sent by libvaxis
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  @impl Mode
  @doc """
  Handles a key event in Replace mode.

  Returns a `t:Minga.Mode.result/0` describing what the editor should do.
  """
  @spec handle_key(Mode.key(), ReplaceState.t()) :: Mode.result()

  # Escape → return to Normal mode
  def handle_key({@escape, _mods}, state) do
    {:transition, :normal, state}
  end

  # Backspace (ASCII DEL 127 or BS 8) → restore previous character
  def handle_key({cp, _mods}, state) when cp in [8, 127] do
    {:execute, :replace_restore, state}
  end

  # Arrow keys — allow cursor movement without leaving Replace mode
  def handle_key({@arrow_up, _mods}, state) do
    {:execute, :move_up, state}
  end

  def handle_key({@arrow_down, _mods}, state) do
    {:execute, :move_down, state}
  end

  def handle_key({@arrow_left, _mods}, state) do
    {:execute, :move_left, state}
  end

  def handle_key({@arrow_right, _mods}, state) do
    {:execute, :move_right, state}
  end

  # Printable Unicode characters → overwrite char under cursor
  def handle_key({codepoint, 0}, state)
      when codepoint >= 32 and codepoint <= 0x10FFFF do
    char = <<codepoint::utf8>>
    {:execute, {:replace_overwrite, char}, state}
  rescue
    ArgumentError -> {:continue, state}
  end

  # Ignore all other keys
  def handle_key(_key, state) do
    {:continue, state}
  end
end
