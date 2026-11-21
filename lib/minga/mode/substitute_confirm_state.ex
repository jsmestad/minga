defmodule Minga.Mode.SubstituteConfirmState do
  @moduledoc """
  FSM state for substitute confirm mode (`:%s/old/new/gc`).

  Keeps the remaining matches in offered order and accepted matches in
  reverse offered order for application. Progress and the first offered line
  do not depend on which matches the user accepts.
  The generic mode dispatcher's `count` is separate from confirmation progress.
  """

  alias Minga.Editing.Search.Match

  @enforce_keys [
    :remaining,
    :total,
    :first_offered_line,
    :pattern,
    :replacement,
    :original_content
  ]
  defstruct [
    :remaining,
    :total,
    :first_offered_line,
    :pattern,
    :replacement,
    :original_content,
    :count,
    ordinal: 1,
    accepted: []
  ]

  @type t :: %__MODULE__{
          remaining: [Match.t()],
          ordinal: pos_integer(),
          total: pos_integer(),
          first_offered_line: non_neg_integer(),
          pattern: String.t(),
          replacement: String.t(),
          original_content: String.t(),
          accepted: [Match.t()],
          count: non_neg_integer() | nil
        }

  @doc "Starts confirmation with at least one match in the order it will be offered."
  @spec new(nonempty_list(Match.t()), String.t(), String.t(), String.t()) :: t()
  def new([%Match{line: line} | _] = matches, pattern, replacement, original_content) do
    %__MODULE__{
      remaining: matches,
      total: length(matches),
      first_offered_line: line,
      pattern: pattern,
      replacement: replacement,
      original_content: original_content
    }
  end

  @doc "Returns the current offer, or nil when all offers have been consumed."
  @spec current_match(t()) :: Match.t() | nil
  def current_match(%__MODULE__{remaining: [match | _]}), do: match
  def current_match(%__MODULE__{remaining: []}), do: nil

  @doc "Returns the one-based ordinal of the last offer shown and the original total."
  @spec progress(t()) :: {pos_integer(), pos_integer()}
  def progress(%__MODULE__{ordinal: ordinal, total: total}), do: {ordinal, total}

  @doc "Returns accepted matches in reverse offered order, ready to apply."
  @spec accepted_matches(t()) :: [Match.t()]
  def accepted_matches(%__MODULE__{accepted: accepted}), do: accepted

  @doc "Returns the line to restore after applying any replacements."
  @spec first_offered_line(t()) :: non_neg_integer()
  def first_offered_line(%__MODULE__{first_offered_line: line}), do: line

  @doc "Accepts the current match and moves to the next offer, if any."
  @spec accept(t()) :: t()
  def accept(%__MODULE__{remaining: [match | rest]} = state) do
    advance(state, rest, [match | state.accepted])
  end

  @doc "Skips the current match and moves to the next offer, if any."
  @spec skip(t()) :: t()
  def skip(%__MODULE__{remaining: [_ | rest]} = state), do: advance(state, rest, state.accepted)

  @doc "Accepts the current and all later offers without revisiting skipped matches."
  @spec accept_remaining(t()) :: t()
  def accept_remaining(%__MODULE__{remaining: remaining, accepted: accepted} = state) do
    %{state | remaining: [], accepted: Enum.reverse(remaining, accepted)}
  end

  @spec advance(t(), [Match.t()], [Match.t()]) :: t()
  defp advance(state, [], accepted), do: %{state | remaining: [], accepted: accepted}

  defp advance(state, remaining, accepted) do
    %{state | remaining: remaining, accepted: accepted, ordinal: state.ordinal + 1}
  end
end
