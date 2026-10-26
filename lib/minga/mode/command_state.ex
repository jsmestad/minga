defmodule Minga.Mode.CommandState do
  @moduledoc """
  FSM state for Command (`:`) mode.

  Owns the command-line input without the leading `:`, its grapheme cursor position, completion selection, and the standard count/leader fields.
  """

  defstruct input: "",
            cursor: 0,
            candidate_index: 0,
            count: nil,
            leader_node: nil,
            leader_keys: []

  @type t :: %__MODULE__{
          input: String.t(),
          cursor: non_neg_integer(),
          candidate_index: integer(),
          count: non_neg_integer() | nil,
          leader_node: Minga.Keymap.Bindings.node_t() | nil,
          leader_keys: [String.t()]
        }

  @doc "Creates command input with the cursor at its end."
  @spec new(String.t()) :: t()
  def new(input \\ "") when is_binary(input), do: replace_input(%__MODULE__{}, input)

  @doc "Replaces command input, moves the cursor to its end, and resets completion selection."
  @spec replace_input(t(), String.t()) :: t()
  def replace_input(%__MODULE__{} = state, input) when is_binary(input) do
    %{state | input: input, cursor: String.length(input), candidate_index: 0}
  end

  @doc "Inserts text at the cursor and resets completion selection."
  @spec insert_text(t(), String.t()) :: t()
  def insert_text(%__MODULE__{input: input, cursor: cursor} = state, text)
      when is_binary(text) do
    {before, after_cursor} = String.split_at(input, cursor)
    prefix = before <> text
    %{state | input: prefix <> after_cursor, cursor: String.length(prefix), candidate_index: 0}
  end

  @doc "Deletes the grapheme before the cursor and resets completion selection."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{cursor: 0} = state), do: state

  def backspace(%__MODULE__{input: input, cursor: cursor} = state) do
    {before, after_cursor} = String.split_at(input, cursor)
    prefix = String.slice(before, 0, cursor - 1)
    %{state | input: prefix <> after_cursor, cursor: String.length(prefix), candidate_index: 0}
  end

  @doc "Moves the cursor by one grapheme within the command input."
  @spec move_cursor(t(), :left | :right) :: t()
  def move_cursor(%__MODULE__{cursor: cursor} = state, :left) do
    %{state | cursor: max(cursor - 1, 0)}
  end

  def move_cursor(%__MODULE__{input: input, cursor: cursor} = state, :right) do
    %{state | cursor: min(cursor + 1, String.length(input))}
  end

  @doc "Moves the completion selection; the presenter wraps it to the candidate count."
  @spec move_candidate(t(), integer()) :: t()
  def move_candidate(%__MODULE__{candidate_index: index} = state, delta)
      when is_integer(delta) do
    %{state | candidate_index: index + delta}
  end
end
