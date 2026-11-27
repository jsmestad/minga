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
            leader_keys: [],
            visual_lines: nil

  @type t :: %__MODULE__{
          input: String.t(),
          cursor: non_neg_integer(),
          candidate_index: integer(),
          count: non_neg_integer() | nil,
          leader_node: Minga.Keymap.Bindings.node_t() | nil,
          leader_keys: [String.t()],
          visual_lines: visual_lines() | nil
        }

  @typedoc "The buffer and text version that supplied the inclusive Visual line bounds."
  @type visual_lines :: {pid(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc "Creates command input with the cursor at its end."
  @spec new(String.t()) :: t()
  def new(input \\ "") when is_binary(input), do: replace_input(%__MODULE__{}, input)

  @doc "Opens the Ex prompt on the exact lines offered by the active Visual selection."
  @spec for_visual(pid(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def for_visual(buffer, version, anchor, cursor) do
    %__MODULE__{visual_lines: {buffer, version, min(anchor, cursor), max(anchor, cursor)}}
    |> replace_input("'<,'>")
  end

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

  @doc "Applies a readline edit (`⌃A`, `⌃E`, `⌃W`, `⌃U`) and resets completion selection when the input changes."
  @spec line_edit(t(), Minga.Editing.LineEdit.edit()) :: t()
  def line_edit(%__MODULE__{input: input, cursor: cursor} = state, edit) do
    case Minga.Editing.LineEdit.apply(edit, input, cursor) do
      {^input, next_cursor} ->
        %{state | cursor: next_cursor}

      {next_input, next_cursor} ->
        %{state | input: next_input, cursor: next_cursor, candidate_index: 0}
    end
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
