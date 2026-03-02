defmodule Minga.Mode.SearchPrompt do
  @moduledoc """
  Search prompt mode for project-wide search.

  Entered via `SPC s p` or `SPC /`. The user types a search query that
  is accumulated in the FSM state. On Enter the query is confirmed and
  the editor runs the project search and opens a picker with results.

  ## Key bindings

  | Key         | Action                                    |
  |-------------|-------------------------------------------|
  | `Enter`     | Confirm query, run project search         |
  | `Escape`    | Cancel, return to normal mode             |
  | `Backspace` | Delete last character; if empty → cancel  |
  | Printable   | Append character to query                 |
  """

  @behaviour Minga.Mode

  alias Minga.Mode
  alias Minga.Mode.SearchPromptState

  @escape 27
  @enter 13

  @impl Mode
  @spec handle_key(Mode.key(), SearchPromptState.t()) :: Mode.result()

  def handle_key({@enter, _mods}, %SearchPromptState{input: ""} = state) do
    {:transition, :normal, state}
  end

  def handle_key({@enter, _mods}, %SearchPromptState{} = state) do
    {:execute_then_transition, [:confirm_project_search], :normal, state}
  end

  def handle_key({@escape, _mods}, %SearchPromptState{} = state) do
    {:transition, :normal, %{state | input: ""}}
  end

  # Backspace
  def handle_key({cp, _mods}, %SearchPromptState{input: input} = state) when cp in [8, 127] do
    case input do
      "" ->
        {:transition, :normal, state}

      _ ->
        new_input = String.slice(input, 0, String.length(input) - 1)
        {:continue, %{state | input: new_input}}
    end
  end

  # Printable characters
  def handle_key({codepoint, 0}, %SearchPromptState{input: input} = state)
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

  # Ignore all other keys
  def handle_key(_key, %SearchPromptState{} = state) do
    {:continue, state}
  end
end
