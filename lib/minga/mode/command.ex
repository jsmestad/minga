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
  | `Escape`    | Cancel, transition to Normal                        |
  | `Backspace` | Delete last character; if empty → Normal            |
  | Printable   | Append character to the command buffer              |

  ## State contract

  Command mode reads and writes `:input` (a `String.t()`) in the shared FSM
  state. The editor injects `input: ""` when transitioning *into* command mode
  (just as it injects `:visual_anchor` for Visual mode).
  """

  @behaviour Minga.Mode

  alias Minga.Command.Parser
  alias Minga.Mode
  alias Minga.Mode.CommandState

  # Special codepoints
  @escape 27
  @enter 13

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

  # Enter → parse the accumulated input and emit an :execute_ex_command
  def handle_key({@enter, _mods}, %CommandState{input: input} = state) do
    parsed = Parser.parse(input)
    {:execute_then_transition, [{:execute_ex_command, parsed}], :normal, %{state | input: ""}}
  end

  # Escape → cancel, return to Normal without executing
  def handle_key({@escape, _mods}, %CommandState{} = state) do
    {:transition, :normal, %{state | input: ""}}
  end

  # Backspace (DEL 127 or BS 8) — remove last char; if empty → Normal
  def handle_key({cp, _mods}, %CommandState{input: input} = state) when cp in [8, 127] do
    case input do
      "" ->
        {:transition, :normal, state}

      _ ->
        new_input = String.slice(input, 0, String.length(input) - 1)

        if new_input == "" do
          {:transition, :normal, %{state | input: ""}}
        else
          {:continue, %{state | input: new_input}}
        end
    end
  end

  # Arrow keys — ignored in command mode (use terminal editing only)
  def handle_key({cp, _mods}, %CommandState{} = state)
      when cp in [@arrow_up, @arrow_down, @arrow_left, @arrow_right] do
    {:continue, state}
  end

  # Printable Unicode characters (no modifiers) → append to input
  def handle_key({codepoint, 0}, %CommandState{input: input} = state)
      when codepoint >= 32 and codepoint <= 0x10FFFF do
    char =
      try do
        <<codepoint::utf8>>
      rescue
        ArgumentError -> nil
      end

    case char do
      nil -> {:continue, state}
      c -> {:continue, %{state | input: input <> c}}
    end
  end

  # Ignore all other keys (control sequences, arrows, etc.)
  def handle_key(_key, %CommandState{} = state) do
    {:continue, state}
  end
end
