defmodule Minga.Editing.Fold.Range do
  @moduledoc """
  A foldable range within a buffer.

  Value object representing a region that *can* be folded (collapsed).
  Produced by fold providers, consumed by `FoldMap`. Two ranges must
  not overlap; the fold map enforces this on insertion.

  Both `start_line` and `end_line` are inclusive, 0-indexed buffer line
  numbers. A range must span at least two lines (`end_line > start_line`).
  """

  @enforce_keys [:start_line, :end_line]
  defstruct [:start_line, :end_line, summary: nil, kind: :block]

  @typedoc """
  Kind of fold range. Used by the renderer to pick icons and by
  org-mode cycling to distinguish heading levels from generic blocks.

  - `:block` — generic code block (function, class, if/for/while)
  - `:comment` — comment block
  - `:import` — import/use/require group
  - `:heading` — org-mode or markdown heading
  """
  @type kind :: :block | :comment | :import | :heading

  @typedoc """
  A foldable range.

  - `start_line` — first line of the range (the "summary" line shown when folded)
  - `end_line` — last line of the range (inclusive)
  - `summary` — optional text shown after the fold line (e.g., "··· 12 lines")
  - `kind` — the type of fold range
  """
  @type t :: %__MODULE__{
          start_line: non_neg_integer(),
          end_line: non_neg_integer(),
          summary: String.t() | nil,
          kind: kind()
        }

  @doc """
  Creates a new fold range.

  Returns `{:ok, range}` if valid, or `{:error, reason}` if the range
  is degenerate (end <= start).
  """
  @spec new(non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, t()} | {:error, String.t()}
  def new(start_line, end_line, opts \\ [])

  def new(start_line, end_line, _opts) when end_line <= start_line do
    {:error, "end_line must be greater than start_line"}
  end

  def new(start_line, end_line, opts) do
    {:ok,
     %__MODULE__{
       start_line: start_line,
       end_line: end_line,
       summary: Keyword.get(opts, :summary),
       kind: Keyword.get(opts, :kind, :block)
     }}
  end

  @doc """
  Creates a new fold range, raising on invalid input.
  """
  @spec new!(non_neg_integer(), non_neg_integer(), keyword()) :: t()
  def new!(start_line, end_line, opts \\ []) do
    case new(start_line, end_line, opts) do
      {:ok, range} -> range
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc "Returns the number of lines hidden when this range is folded (excludes the summary line)."
  @spec hidden_count(t()) :: pos_integer()
  def hidden_count(%__MODULE__{start_line: s, end_line: e}), do: e - s

  @doc "Returns true if the given buffer line falls within this range (inclusive)."
  @spec contains?(t(), non_neg_integer()) :: boolean()
  def contains?(%__MODULE__{start_line: s, end_line: e}, line), do: line >= s and line <= e

  @doc "Returns true if the given buffer line is hidden by this fold (inside but not the start line)."
  @spec hides?(t(), non_neg_integer()) :: boolean()
  def hides?(%__MODULE__{start_line: s, end_line: e}, line), do: line > s and line <= e

  @doc "Returns true if two ranges overlap."
  @spec overlaps?(t(), t()) :: boolean()
  def overlaps?(%__MODULE__{start_line: s1, end_line: e1}, %__MODULE__{
        start_line: s2,
        end_line: e2
      }) do
    s1 <= e2 and s2 <= e1
  end
end
