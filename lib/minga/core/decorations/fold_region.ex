defmodule Minga.Core.Decorations.FoldRegion do
  @moduledoc """
  A buffer-level fold region decoration: a collapsible range with a
  custom placeholder.

  Unlike per-window folds (managed by `FoldMap`), decoration folds are
  per-buffer. Every window showing the buffer sees the same fold state.
  This is the right model for agent chat thinking blocks, tool output,
  and other decoration-driven collapsible content.

  The `placeholder` callback receives the fold's start line, end line,
  and available width, and returns styled segments for the summary line
  shown when the fold is closed.
  """

  @enforce_keys [:id, :start_line, :end_line]
  defstruct id: nil,
            start_line: 0,
            end_line: 0,
            closed: true,
            placeholder: nil,
            group: nil

  @typedoc """
  Placeholder render callback for a closed fold region.

  Receives (start_line, end_line, width) and returns styled segments.
  When nil, the default placeholder "··· N lines" is used.
  """
  @type placeholder_fn ::
          (non_neg_integer(), non_neg_integer(), pos_integer() ->
             [{String.t(), Minga.UI.Face.t()}])
          | nil

  @type t :: %__MODULE__{
          id: reference(),
          start_line: non_neg_integer(),
          end_line: non_neg_integer(),
          closed: boolean(),
          placeholder: placeholder_fn(),
          group: term() | nil
        }

  @doc "Returns the number of lines hidden when this fold is closed."
  @spec hidden_count(t()) :: non_neg_integer()
  def hidden_count(%__MODULE__{start_line: s, end_line: e}), do: e - s

  @doc "Returns true if the given buffer line is hidden by this closed fold."
  @spec hides?(t(), non_neg_integer()) :: boolean()
  def hides?(%__MODULE__{closed: false}, _line), do: false

  def hides?(%__MODULE__{start_line: s, end_line: e}, line) do
    line > s and line <= e
  end

  @doc "Returns true if the given buffer line is within this fold (start inclusive, end inclusive)."
  @spec contains?(t(), non_neg_integer()) :: boolean()
  def contains?(%__MODULE__{start_line: s, end_line: e}, line) do
    line >= s and line <= e
  end
end
