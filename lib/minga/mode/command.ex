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
  | `Backspace`, `⌃H` | Delete before cursor; if empty → Normal        |
  | `⌃J` / `⌃K`, `↓` / `↑` | Navigate completion candidates            |
  | `⌃A` / `⌃E` | Move to the start / end of the input               |
  | `⌃W` / `⌃U` | Delete the word before the cursor / to the start   |
  | `←` / `→`  | Move the cursor within the command input             |
  | Printable   | Insert character at the command cursor               |

  ## State contract

  `Minga.Mode.CommandState` owns the input string and its grapheme cursor position. The editor creates an empty command state when entering command mode.
  """

  @behaviour Minga.Mode

  alias Minga.Command.Parser, as: CommandParser
  alias Minga.Editing.LineEdit
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.PromptKeys
  alias Minga.Mode
  alias Minga.Mode.CommandState

  # Arrow key codepoints sent by libvaxis (exclude from printable range)
  @arrow_left 57_350
  @arrow_right 57_351

  @impl Mode
  @doc """
  Handles a key event in Command mode.

  The key resolves through the prompt trie in `Minga.Keymap.PromptKeys` (the `:prompt` keymap scope, with a list) first; any other key edits the input.

  Returns a `t:Minga.Mode.result/0` describing the FSM transition.
  """
  @spec handle_key(Mode.key(), CommandState.t()) :: Mode.result()
  def handle_key(key, %CommandState{} = state) do
    case Bindings.lookup(PromptKeys.prompt_trie(list: true), key) do
      {:command, command} -> run(command, state)
      _unbound -> edit(key, state)
    end
  end

  @spec run(atom(), CommandState.t()) :: Mode.result()

  # Enter → execute the highlighted candidate if navigated, otherwise parse raw input
  defp run(:prompt_submit, %CommandState{input: input, candidate_index: idx} = state)
       when idx != 0 do
    {:execute_then_transition, [{:execute_command_candidate, input, idx}], :normal,
     CommandState.replace_input(state, "")}
  end

  defp run(:prompt_submit, %CommandState{input: input} = state) do
    parsed = CommandParser.parse(input)

    {:execute_then_transition, [{:execute_ex_command, parsed}], :normal,
     CommandState.replace_input(state, "")}
  end

  # Escape → cancel, return to Normal without executing
  defp run(:prompt_cancel, state),
    do: {:transition, :normal, CommandState.replace_input(state, "")}

  # Tab → accept selected completion candidate
  defp run(:prompt_complete, state), do: {:execute, [{:accept_command_candidate}], state}

  defp run(:prompt_next, state), do: {:continue, CommandState.move_candidate(state, 1)}
  defp run(:prompt_prev, state), do: {:continue, CommandState.move_candidate(state, -1)}

  @spec edit(Mode.key(), CommandState.t()) :: Mode.result()

  # Backspace and ⌃H remove the grapheme before the cursor; empty input returns to Normal.
  defp edit({cp, _mods}, state) when cp in [8, 127], do: delete_backward(state)

  defp edit({@arrow_left, _mods}, state), do: {:continue, CommandState.move_cursor(state, :left)}

  defp edit({@arrow_right, _mods}, state),
    do: {:continue, CommandState.move_cursor(state, :right)}

  # Printable Unicode characters insert at the cursor and reset completion selection.
  defp edit({codepoint, 0}, state) when codepoint >= 32 and codepoint <= 0x10FFFF do
    case printable_char(codepoint) do
      nil -> {:continue, state}
      char -> {:continue, CommandState.insert_text(state, char)}
    end
  end

  defp edit(key, state) do
    case LineEdit.edit_for_key(key) do
      nil -> {:continue, state}
      :delete_backward -> delete_backward(state)
      edit -> {:continue, CommandState.line_edit(state, edit)}
    end
  end

  @spec delete_backward(CommandState.t()) :: Mode.result()
  defp delete_backward(state) do
    case CommandState.backspace(state) do
      %CommandState{input: ""} = next -> {:transition, :normal, next}
      next -> {:continue, next}
    end
  end

  @spec printable_char(non_neg_integer()) :: String.t() | nil
  defp printable_char(codepoint) do
    <<codepoint::utf8>>
  rescue
    ArgumentError -> nil
  end
end
