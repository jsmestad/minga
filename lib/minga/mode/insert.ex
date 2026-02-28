defmodule Minga.Mode.Insert do
  @moduledoc """
  Vim Insert mode key handler.

  In Insert mode, most key presses insert the corresponding character into
  the buffer. A small number of special keys have dedicated meanings:

  | Key       | Action                              |
  |-----------|-------------------------------------|
  | `Escape`  | Transition back to Normal mode      |
  | Backspace | Delete character before cursor      |
  | Enter     | Insert a newline                    |
  | Arrow keys| Move cursor (without leaving Insert)|
  | Other     | Insert the UTF-8 character          |
  """

  @behaviour Minga.Mode

  alias Minga.Mode

  # Special codepoints
  @escape 27
  @enter 13

  # Arrow key codepoints sent by libvaxis
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  @impl Mode
  @doc """
  Handles a key event in Insert mode.

  Returns a `t:Minga.Mode.result/0` indicating what the editor should do.
  """
  @spec handle_key(Mode.key(), Mode.state()) :: Mode.result()

  # Escape → back to Normal
  def handle_key({@escape, _mods}, state) do
    {:transition, :normal, state}
  end

  # Backspace (ASCII DEL 127 or BS 8)
  def handle_key({cp, _mods}, state) when cp in [8, 127] do
    {:execute, :delete_before, state}
  end

  # Enter
  def handle_key({@enter, _mods}, state) do
    {:execute, :insert_newline, state}
  end

  # Arrow keys — allow cursor movement without leaving Insert mode
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

  # Printable Unicode characters (codepoints 32..0x10FFFF, no modifiers)
  def handle_key({codepoint, 0}, state)
      when codepoint >= 32 and codepoint <= 0x10FFFF do
    char = <<codepoint::utf8>>
    {:execute, {:insert_char, char}, state}
  rescue
    ArgumentError -> {:continue, state}
  end

  # Ignore all other keys (control sequences, unknown modifiers, etc.)
  def handle_key(_key, state) do
    {:continue, state}
  end
end
