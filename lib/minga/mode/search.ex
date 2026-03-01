defmodule Minga.Mode.Search do
  @moduledoc """
  Search mode key handler (`/` and `?` search prompt).

  Search mode is entered from Normal mode when `/` or `?` is pressed. The
  user types a search pattern that is accumulated in the FSM state under
  `:input`. Each character emits an `:incremental_search` command to jump
  the cursor to the next match as you type.

  ## Key bindings

  | Key         | Action                                        |
  |-------------|-----------------------------------------------|
  | `Enter`     | Confirm search, transition to Normal           |
  | `Escape`    | Cancel search, restore cursor, transition to Normal |
  | `Backspace` | Delete last character; if empty → cancel       |
  | Printable   | Append character, trigger incremental search   |
  """

  @behaviour Minga.Mode

  alias Minga.Mode
  alias Minga.Mode.SearchState

  # Special codepoints
  @escape 27
  @enter 13

  # Arrow key codepoints (ignore in search mode)
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  @impl Mode
  @doc """
  Handles a key event in Search mode.

  Returns a `t:Minga.Mode.result/0` describing the FSM transition.
  """
  @spec handle_key(Mode.key(), SearchState.t()) :: Mode.result()

  # Enter → confirm the search and return to Normal
  def handle_key({@enter, _mods}, %SearchState{input: input} = state) do
    if input == "" do
      {:transition, :normal, %{state | input: ""}}
    else
      # Keep input intact — confirm_search reads ms.input to store the pattern.
      {:execute_then_transition, [:confirm_search], :normal, state}
    end
  end

  # Escape → cancel, restore cursor, return to Normal
  def handle_key({@escape, _mods}, %SearchState{} = state) do
    {:execute_then_transition, [:cancel_search], :normal, %{state | input: ""}}
  end

  # Backspace — remove last char; if empty → cancel
  def handle_key({cp, _mods}, %SearchState{input: input} = state) when cp in [8, 127] do
    case input do
      "" ->
        {:execute_then_transition, [:cancel_search], :normal, state}

      _ ->
        new_input = String.slice(input, 0, String.length(input) - 1)

        if new_input == "" do
          {:execute, :incremental_search, %{state | input: new_input}}
        else
          {:execute, :incremental_search, %{state | input: new_input}}
        end
    end
  end

  # Arrow keys — ignored in search mode
  def handle_key({cp, _mods}, %SearchState{} = state)
      when cp in [@arrow_up, @arrow_down, @arrow_left, @arrow_right] do
    {:continue, state}
  end

  # Printable Unicode characters → append to input, trigger incremental search
  def handle_key({codepoint, 0}, %SearchState{input: input} = state)
      when codepoint >= 32 and codepoint <= 0x10FFFF do
    char =
      try do
        <<codepoint::utf8>>
      rescue
        ArgumentError -> nil
      end

    case char do
      nil -> {:continue, state}
      c -> {:execute, :incremental_search, %{state | input: input <> c}}
    end
  end

  # Ignore all other keys
  def handle_key(_key, %SearchState{} = state) do
    {:continue, state}
  end
end
