defmodule Minga.Mode.Command do
  @moduledoc """
  Vim Command mode (`:` command line) key handler.

  Command mode is entered from Normal mode when `:` is pressed. The user
  types a command string that is accumulated in the FSM state under the
  `:input` key. Pressing **Enter** parses and executes the command, then
  returns to Normal mode. Pressing **Escape** (or **Backspace** on an empty
  buffer) cancels without executing.

  ## Key bindings

  | Key         | Action                                              |
  |-------------|-----------------------------------------------------|
  | `Enter`     | Parse + execute command, transition to Normal       |
  | `Tab`       | Accept selected completion candidate                |
  | `Escape`    | Cancel, transition to Normal                        |
  | `Backspace` | Delete before cursor; if empty → Normal              |
  | `↑` / `↓`  | Navigate completion candidates                      |
  | `←` / `→`  | Move the cursor within the command input             |
  | Printable   | Insert character at the command cursor               |

  ## State contract

  `Minga.Mode.CommandState` owns the input string and its grapheme cursor position. The editor creates an empty command state when entering command mode.
  """

  @behaviour Minga.Mode

  import Bitwise

  alias Minga.Command.Parser, as: CommandParser
  alias Minga.Mode
  alias Minga.Mode.CommandState

  # Special codepoints
  @escape 27
  @enter 13
  @tab 9
  @ctrl 0x02

  # Arrow key codepoints sent by libvaxis (exclude from printable range)
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  @impl Mode
  @doc """
  Handles a key event in Command mode.

  Returns a `t:Minga.Mode.result/0` describing the FSM transition.
  """
  @spec handle_key(Mode.key(), CommandState.t()) :: Mode.result()

  # Enter → execute the highlighted candidate if navigated, otherwise parse raw input
  def handle_key({@enter, _mods}, %CommandState{input: input, candidate_index: idx} = state)
      when idx != 0 do
    {:execute_then_transition, [{:execute_command_candidate, input, idx}], :normal,
     CommandState.replace_input(state, "")}
  end

  def handle_key({@enter, _mods}, %CommandState{input: input} = state) do
    parsed = CommandParser.parse(input)

    {:execute_then_transition, [{:execute_ex_command, parsed}], :normal,
     CommandState.replace_input(state, "")}
  end

  # Escape → cancel, return to Normal without executing
  def handle_key({@escape, _mods}, %CommandState{} = state) do
    {:transition, :normal, CommandState.replace_input(state, "")}
  end

  # Backspace removes the grapheme before the cursor; empty input returns to Normal.
  def handle_key({cp, _mods}, %CommandState{} = state) when cp in [8, 127] do
    case CommandState.backspace(state) do
      %CommandState{input: ""} = next -> {:transition, :normal, next}
      next -> {:continue, next}
    end
  end

  # Tab → accept selected completion candidate
  def handle_key({@tab, _mods}, %CommandState{} = state) do
    {:execute, [{:accept_command_candidate}], state}
  end

  # Arrow up → move candidate selection up
  def handle_key({@arrow_up, _mods}, %CommandState{} = state) do
    {:continue, CommandState.move_candidate(state, -1)}
  end

  # Arrow down → move candidate selection down
  def handle_key({@arrow_down, _mods}, %CommandState{} = state) do
    {:continue, CommandState.move_candidate(state, 1)}
  end

  # C-p → move candidate selection up (vim convention)
  def handle_key({?p, mods}, %CommandState{} = state)
      when band(mods, @ctrl) != 0 do
    {:continue, CommandState.move_candidate(state, -1)}
  end

  # C-n → move candidate selection down (vim convention)
  def handle_key({?n, mods}, %CommandState{} = state)
      when band(mods, @ctrl) != 0 do
    {:continue, CommandState.move_candidate(state, 1)}
  end

  def handle_key({@arrow_left, _mods}, %CommandState{} = state) do
    {:continue, CommandState.move_cursor(state, :left)}
  end

  def handle_key({@arrow_right, _mods}, %CommandState{} = state) do
    {:continue, CommandState.move_cursor(state, :right)}
  end

  # Printable Unicode characters insert at the cursor and reset completion selection.
  def handle_key({codepoint, 0}, %CommandState{} = state)
      when codepoint >= 32 and codepoint <= 0x10FFFF do
    char =
      try do
        <<codepoint::utf8>>
      rescue
        ArgumentError -> nil
      end

    case char do
      nil -> {:continue, state}
      c -> {:continue, CommandState.insert_text(state, c)}
    end
  end

  # Ignore all other keys (control sequences, arrows, etc.)
  def handle_key(_key, %CommandState{} = state) do
    {:continue, state}
  end
end
