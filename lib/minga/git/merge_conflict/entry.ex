defmodule Minga.Git.MergeConflict.Entry do
  @moduledoc """
  Lightweight line coordinates and labels for one complete merge conflict.

  Unlike `Minga.Git.MergeConflict.Region`, this value does not copy either side's text. It is safe to retain and update on the buffer edit path even when one conflict contains many lines.
  """

  @enforce_keys [
    :start_line,
    :separator_line,
    :end_line,
    :current_range,
    :incoming_range,
    :current_label,
    :incoming_label
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
    :incoming_label
  ]

  @typedoc "Inclusive marker-free line range. Empty sides use a range whose end is before its start."
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
          incoming_label: String.t()
        }

  @doc "Builds an entry from its marker coordinates and labels."
  @spec new(
          non_neg_integer(),
          non_neg_integer() | nil,
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          String.t() | nil,
          String.t()
        ) :: t()
  def new(start_line, nil, separator_line, end_line, current_label, nil, incoming_label) do
    %__MODULE__{
      start_line: start_line,
      current_range: {start_line + 1, separator_line - 1},
      separator_line: separator_line,
      incoming_range: {separator_line + 1, end_line - 1},
      end_line: end_line,
      current_label: current_label,
      incoming_label: incoming_label
    }
  end

  def new(
        start_line,
        base_line,
        separator_line,
        end_line,
        current_label,
        base_label,
        incoming_label
      ) do
    %__MODULE__{
      start_line: start_line,
      current_range: {start_line + 1, base_line - 1},
      base_marker_line: base_line,
      base_range: {base_line + 1, separator_line - 1},
      separator_line: separator_line,
      incoming_range: {separator_line + 1, end_line - 1},
      end_line: end_line,
      current_label: current_label,
      base_label: base_label,
      incoming_label: incoming_label
    }
  end
end
