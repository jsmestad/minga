defmodule MingaAgent.EditBoundary do
  @moduledoc """
  Defines a line range that an agent session is allowed to edit within a buffer.

  Boundaries are per-buffer, per-session. When set, agent edits outside the
  boundary are rejected with a descriptive error. Boundaries adjust automatically
  when edits change the line count within the bounded region or when user edits
  above the boundary shift line numbers.
  """

  @enforce_keys [:start_line, :end_line]
  defstruct [:start_line, :end_line]

  @typedoc "A line range boundary (both inclusive, 0-indexed)."
  @type t :: %__MODULE__{
          start_line: non_neg_integer(),
          end_line: non_neg_integer()
        }

  @doc """
  Creates a new boundary for the given line range (both inclusive, 0-indexed).

  Returns `{:error, reason}` if the range is invalid.
  """
  @spec new(non_neg_integer(), non_neg_integer()) :: {:ok, t()} | {:error, String.t()}
  def new(start_line, end_line)
      when is_integer(start_line) and is_integer(end_line) and start_line >= 0 and
             end_line >= start_line do
    {:ok, %__MODULE__{start_line: start_line, end_line: end_line}}
  end

  def new(start_line, end_line)
      when is_integer(start_line) and is_integer(end_line) do
    {:error, "invalid boundary: start_line (#{start_line}) must be <= end_line (#{end_line})"}
  end

  @doc """
  Checks whether a line falls within the boundary (inclusive on both ends).
  """
  @spec contains_line?(t(), non_neg_integer()) :: boolean()
  def contains_line?(%__MODULE__{start_line: s, end_line: e}, line)
      when is_integer(line) do
    line >= s and line <= e
  end

  @doc """
  Checks whether a line range (start..end, both inclusive) falls entirely within the boundary.
  """
  @spec contains_range?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def contains_range?(%__MODULE__{start_line: s, end_line: e}, range_start, range_end)
      when is_integer(range_start) and is_integer(range_end) do
    range_start >= s and range_end <= e
  end

  @doc """
  Adjusts the boundary after an edit changed the line count.

  `edit_line` is the 0-indexed line where the edit started. `line_delta` is the
  number of lines added (positive) or removed (negative) by the edit.

  - Edits within the boundary: the end shifts by `line_delta`.
  - Edits above the boundary: both start and end shift by `line_delta`.
  - Edits below the boundary: no change.

  Returns `nil` if the boundary collapses to zero or negative size (e.g., the
  user deleted all lines within the boundary).
  """
  @spec adjust(t(), non_neg_integer(), integer()) :: t() | nil
  def adjust(%__MODULE__{start_line: s, end_line: e}, edit_line, line_delta) do
    cond do
      # Edit is below the boundary: no adjustment needed
      edit_line > e ->
        %__MODULE__{start_line: s, end_line: e}

      # Edit is above the boundary: shift both start and end
      edit_line < s ->
        new_start = max(s + line_delta, 0)
        new_end = max(e + line_delta, 0)

        if new_end >= new_start do
          %__MODULE__{start_line: new_start, end_line: new_end}
        else
          nil
        end

      # Edit is within the boundary: only shift the end
      true ->
        new_end = max(e + line_delta, s)

        if new_end >= s do
          %__MODULE__{start_line: s, end_line: new_end}
        else
          nil
        end
    end
  end
end
