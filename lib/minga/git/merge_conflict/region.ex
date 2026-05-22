defmodule Minga.Git.MergeConflict.Region do
  @moduledoc """
  Parsed line-based Git merge conflict region.

  Line numbers are zero-indexed and inclusive. Side ranges point at marker-free content lines. `current_lines`, `base_lines`, and `incoming_lines` are the marker-free text lines used by resolution commands.
  """

  @enforce_keys [
    :start_line,
    :separator_line,
    :end_line,
    :current_range,
    :incoming_range,
    :current_label,
    :incoming_label,
    :current_lines,
    :incoming_lines
  ]
  defstruct [
    :start_line,
    :separator_line,
    :end_line,
    :base_marker_line,
    :current_range,
    :base_range,
    :incoming_range,
    :current_label,
    :base_label,
    :incoming_label,
    :current_lines,
    :base_lines,
    :incoming_lines
  ]

  @typedoc "Inclusive marker-free line range. Empty sides use the sentinel `{start_line, end_line}` with `end_line < start_line`."
  @type line_range :: {start_line :: non_neg_integer(), end_line :: integer()}

  @type t :: %__MODULE__{
          start_line: non_neg_integer(),
          separator_line: non_neg_integer(),
          end_line: non_neg_integer(),
          base_marker_line: non_neg_integer() | nil,
          current_range: line_range(),
          base_range: line_range() | nil,
          incoming_range: line_range(),
          current_label: String.t(),
          base_label: String.t() | nil,
          incoming_label: String.t(),
          current_lines: [String.t()],
          base_lines: [String.t()] | nil,
          incoming_lines: [String.t()]
        }

  @doc "Returns true when a marker-free side range is empty."
  @spec empty_range?(line_range()) :: boolean()
  def empty_range?({start_line, end_line}) when is_integer(start_line) and is_integer(end_line),
    do: end_line < start_line
end
