defmodule Minga.Mode.Eval do
  @moduledoc """
  Eval mode (`M-:`) key handler.

  Eval mode is entered from Normal mode when `Alt+:` is pressed. The user
  types an Elixir expression that is accumulated in the FSM state under the
  `:input` key. Pressing **Enter** evaluates the expression, then returns
  to Normal mode. Pressing **Escape** (or **Backspace** on an empty buffer)
  cancels without evaluating.

  ## Key bindings

  | Key         | Action                                              |
  |-------------|-----------------------------------------------------|
  | `Enter`     | Evaluate expression, transition to Normal           |
  | `Escape`    | Cancel, transition to Normal                        |
  | `Backspace` | Delete last character; if empty → Normal            |
  | Printable   | Append character to the input buffer                |
  """

  @behaviour Minga.Mode

  alias Minga.Mode
  alias Minga.Mode.EvalState

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
  Handles a key event in Eval mode.

  Returns a `t:Minga.Mode.result/0` describing the FSM transition.
  """
  @spec handle_key(Mode.key(), EvalState.t()) :: Mode.result()

  # Enter → evaluate the accumulated input
  def handle_key({@enter, _mods}, %EvalState{input: ""} = state) do
    {:transition, :normal, %{state | input: ""}}
  end

  def handle_key({@enter, _mods}, %EvalState{input: input} = state) do
    {:execute_then_transition, [{:eval_expression, input}], :normal, %{state | input: ""}}
  end

  # Escape → cancel, return to Normal without evaluating
  def handle_key({@escape, _mods}, %EvalState{} = state) do
    {:transition, :normal, %{state | input: ""}}
  end

  # Backspace (DEL 127 or BS 8) — remove last char; if empty → Normal
  def handle_key({cp, _mods}, %EvalState{input: input} = state) when cp in [8, 127] do
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

  # Arrow keys — ignored in eval mode
  def handle_key({cp, _mods}, %EvalState{} = state)
      when cp in [@arrow_up, @arrow_down, @arrow_left, @arrow_right] do
    {:continue, state}
  end

  # Printable Unicode characters (no modifiers) → append to input
  def handle_key({codepoint, 0}, %EvalState{input: input} = state)
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

  # Ignore all other keys (control sequences, etc.)
  def handle_key(_key, %EvalState{} = state) do
    {:continue, state}
  end
end
